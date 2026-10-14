import AVFoundation
import AudioToolbox
import CoreAudio

/// マイクから 16kHz・モノラル・16bit PCM の .wav に落とす。whisper.cpp がこの形式を前提にする。
final class Recorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    enum RecorderError: LocalizedError {
        case noInput
        case converterUnavailable
        case fileCreationFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInput: return "マイク入力が見つかりません。入力デバイスと権限を確認してください。"
            case .converterUnavailable: return "録音フォーマットの変換器を作れませんでした。"
            case .fileCreationFailed(let m): return "録音ファイルを作れませんでした: \(m)"
            }
        }
    }

    /// 権限が付く前に inputNode を触ると 0Hz のフォーマットを掴んだままになる。
    /// 録音のたびに作り直して、その状態を持ち越さない。
    private var engine = AVAudioEngine()
    private var session: AVCaptureSession?
    private let sampleQueue = DispatchQueue(label: "com.ishot.voice-input.samples")
    private var usesSession: Bool { CommandLine.arguments.contains("--capture-worker") }
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let lock = NSLock()

    private(set) var isRecording = false
    private(set) var currentURL: URL?
    /// 声が入っているかの判定に使う。無音のまま止めたときに気づけるようにする。
    private(set) var peakLevel: Float = 0
    /// ピークだけだと物音ひとつで越えてしまう。全体の大きさも見る。
    private var squareSum: Double = 0
    private(set) var writtenFrames: Int64 = 0
    private var startedAt: Date?
    private var monitor: Timer?
    private var observedFrames: Int64 = 0
    private var lastProgress = Date()
    private var recoveryAttempts = 0
    private var tapInstalled = false
    private var reconnecting = false
    private var generation = UUID()
    private var useBuiltInMicrophone = false
    private var captureProcess: Process?
    private var captureControl: Pipe?
    private var captureReader: DispatchGroup?
    var outputURL: URL?
    var onFailure: ((String) -> Void)?

    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000,
                                            channels: 1,
                                            interleaved: false)!

    /// 収録中のレベル（0.0〜1.0）を返す。メニューバーの表示に使う。
    var onLevel: ((Float) -> Void)?
    var onSamples: (([Float]) -> Void)?
    var onReady: (() -> Void)?

    func start() throws {
        guard !isRecording else { return }
        if !CommandLine.arguments.contains("--capture-worker") && !CommandLine.arguments.contains("--recorder-recovery-test") && !CommandLine.arguments.contains("--mic-test") {
            try startWorker(); return
        }
        peakLevel = 0
        squareSum = 0
        writtenFrames = 0
        engine = AVAudioEngine()
        generation = UUID(); reconnecting = false

        let inputFormat = usesSession ? Self.targetFormat : engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInput
        }

        let url = outputURL ?? Paths.tmp.appendingPathComponent("rec-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            // 書き込みは float32/16kHz/mono で行い、ファイル自体は 16bit PCM で保存される
            file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw RecorderError.fileCreationFailed(error.localizedDescription)
        }
        currentURL = url

        try attachInput()
        isRecording = true
        startedAt = Date()
        observedFrames = 0; recoveryAttempts = 0; lastProgress = Date()
        monitor = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkInput() }
        Log.write("録音開始 input=\(Int(inputFormat.sampleRate))Hz/\(inputFormat.channelCount)ch → \(url.lastPathComponent)")
    }

    private func attachInput() throws {
        if usesSession { try attachSession(); return }
        let input = engine.inputNode
        if useBuiltInMicrophone, var device = Self.builtInInput(), let unit = input.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                             kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            Log.write("通常録音: 内蔵マイクへの切替 status=\(status)")
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw RecorderError.noInput }
        guard let conv = AVAudioConverter(from: inputFormat, to: Recorder.targetFormat) else {
            throw RecorderError.converterUnavailable
        }
        conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        converter = conv

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer, from: inputFormat)
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw error
        }

    }

    private func checkInput() {
        guard isRecording, !reconnecting else { return }
        lock.lock(); let frames = writtenFrames; lock.unlock()
        if frames != observedFrames { observedFrames = frames; lastProgress = Date(); recoveryAttempts = 0 }
        guard !(session?.isRunning ?? engine.isRunning) || Date().timeIntervalSince(lastProgress) > 1.5 else { return }
        guard recoveryAttempts < 3 else {
            monitor?.invalidate(); monitor = nil
            onFailure?("マイクから音声データが届かず、再接続もできませんでした。入力デバイスを確認してください。")
            return
        }
        recoveryAttempts += 1
        useBuiltInMicrophone = true
        Log.write("通常録音: 音声データ停止を検出、マイク再接続 \(recoveryAttempts)/3")
        session?.stopRunning(); sampleQueue.sync {}; session = nil
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop()
        lock.lock(); converter = nil; lock.unlock()
        engine = AVAudioEngine()
        lastProgress = Date()
        reconnecting = true
        let currentGeneration = generation
        // Let CoreAudio tear down the old input before opening a new one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.isRecording, self.generation == currentGeneration else { return }
            defer { self.reconnecting = false }
            do {
                try self.attachInput()
                self.lastProgress = Date()
                Log.write("通常録音: 再接続 running=\(self.engine.isRunning)")
            } catch { Log.write("通常録音: 再接続失敗 " + error.localizedDescription) }
        }
    }

    private func attachSession() throws {
        let devices = AVCaptureDevice.devices(for: .audio)
        let device = useBuiltInMicrophone
            ? devices.first(where: { $0.localizedName.contains("MacBook") || $0.localizedName.contains("Built-in") }) ?? AVCaptureDevice.default(for: .audio)
            : AVCaptureDevice.default(for: .audio)
        guard let device else { throw RecorderError.noInput }
        let capture = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
        guard capture.canAddInput(input), capture.canAddOutput(output) else { throw RecorderError.noInput }
        capture.addInput(input); capture.addOutput(output)
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        converter = AVAudioConverter(from: Self.targetFormat, to: Self.targetFormat)
        session = capture
        capture.startRunning()
        Log.write("通常録音: AVCapture入力=\(device.localizedName) running=\(capture.isRunning)")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return }
        guard CMBlockBufferGetDataLength(block) == count * MemoryLayout<Float>.size else { return }
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: channel) == noErr else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        append(buffer, from: Self.targetFormat)
    }

    private func append(_ buffer: AVAudioPCMBuffer, from inputFormat: AVAudioFormat) {
        lock.lock()
        defer { lock.unlock() }
        guard let conv = converter, let file = file else { return }

        let ratio = Recorder.targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: Recorder.targetFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        let status = conv.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            Log.write("変換に失敗: \(error?.localizedDescription ?? "不明")")
            return
        }
        guard out.frameLength > 0 else { return }

        if let ch = out.floatChannelData?[0] {
            var peak: Float = 0
            var sum: Double = 0
            for i in 0..<Int(out.frameLength) {
                let v = ch[i]
                peak = max(peak, abs(v))
                sum += Double(v) * Double(v)
            }
            if peak > peakLevel { peakLevel = peak }
            squareSum += sum
            let level = peak
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        }

        do {
            try file.write(from: out)
            writtenFrames += Int64(out.frameLength)
            if let channel = out.floatChannelData?[0] {
                onSamples?(Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength))))
            }
        } catch {
            Log.write("書き込みに失敗: \(error.localizedDescription)")
        }
    }

    struct Recording {
        let url: URL
        let duration: TimeInterval
        let peak: Float
        /// 全体の平均的な大きさ。静かな部屋は 0.001 前後、話すと 0.02 以上になる。
        let rms: Float

        /// 声が入っていないと判断できるか。
        /// ピークだけで見ると、物音ひとつで「入っている」ことになってしまう。
        var looksSilent: Bool { peak < 0.02 || rms < 0.004 }
        var tooShort: Bool { duration < 0.4 }
    }

    @discardableResult
    func stop() -> Recording? {
        guard isRecording else { return nil }
        if captureProcess != nil { return stopWorker() }
        isRecording = false
        generation = UUID(); reconnecting = false
        monitor?.invalidate(); monitor = nil
        session?.stopRunning(); sampleQueue.sync {}; session = nil
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop()

        lock.lock()
        file = nil          // ここで閉じてヘッダが書かれる
        converter = nil
        lock.unlock()

        guard let url = currentURL else { return nil }
        let duration = Double(writtenFrames) / Recorder.targetFormat.sampleRate
        let rms = writtenFrames > 0 ? Float((squareSum / Double(writtenFrames)).squareRoot()) : 0
        Log.write(String(format: "録音停止 %.2f秒 peak=%.3f rms=%.4f", duration, peakLevel, rms))
        currentURL = nil
        return Recording(url: url, duration: duration, peak: peakLevel, rms: rms)
    }

    func discard() {
        let discardedURL = currentURL
        if isRecording { _ = stop() }
        engine.stop()
        lock.lock(); file = nil; converter = nil; currentURL = nil; lock.unlock()
        if let url = discardedURL { try? FileManager.default.removeItem(at: url) }
    }

    private func startWorker() throws {
        let url = Paths.tmp.appendingPathComponent("rec-\(UUID().uuidString).wav")
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--capture-worker", url.path]
        child.standardInput = input; child.standardOutput = output
        child.standardError = FileHandle.standardError
        peakLevel = 0; squareSum = 0; writtenFrames = 0
        currentURL = url
        let group = DispatchGroup(); group.enter()
        try child.run()
        captureProcess = child; captureControl = input; captureReader = group
        isRecording = true
        let token = UUID(); generation = token
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { group.leave() }
            var pending = Data()
            var notifiedReady = false
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                pending.append(data)
                let count = pending.count / MemoryLayout<Float>.size
                if count == 0 { continue }
                let bytes = count * MemoryLayout<Float>.size
                let samples: [Float] = pending.prefix(bytes).withUnsafeBytes { buffer in
                    (0..<count).map { buffer.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
                }
                pending.removeFirst(bytes)
                guard let self else { break }
                self.lock.lock()
                self.writtenFrames += Int64(samples.count)
                let peak = samples.map { abs($0) }.max() ?? 0
                self.peakLevel = max(self.peakLevel, peak)
                self.squareSum += samples.reduce(0) { $0 + Double($1) * Double($1) }
                self.lock.unlock()
                if !notifiedReady {
                    notifiedReady = true
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isRecording, self.generation == token else { return }
                        self.onReady?()
                    }
                }
                self.onSamples?(samples)
                DispatchQueue.main.async { [weak self] in self?.onLevel?(peak) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRecording, self.generation == token else { return }
                self.onFailure?("録音用プロセスが停止しました。取得済みの音声は保持します。")
            }
        }
        Log.write("通常録音: 独立した録音プロセスを開始 pid=\(child.processIdentifier)")
    }

    private func stopWorker() -> Recording? {
        guard let child = captureProcess, let url = currentURL else { return nil }
        isRecording = false; generation = UUID()
        // EOF also stops recording if the parent app unexpectedly exits.
        try? captureControl?.fileHandleForWriting.close()
        child.waitUntilExit()
        captureReader?.wait()
        captureProcess = nil; captureControl = nil; captureReader = nil; currentURL = nil
        lock.lock(); defer { lock.unlock() }
        let duration = Double(writtenFrames) / Self.targetFormat.sampleRate
        let rms = writtenFrames > 0 ? Float(sqrt(squareSum / Double(writtenFrames))) : 0
        Log.write("通常録音: 独立プロセス終了 duration=\(duration) status=\(child.terminationStatus)")
        return Recording(url: url, duration: duration, peak: peakLevel, rms: rms)
    }

    /// Real device regression: preserve PCM before and after a stopped engine.
    static func recoveryTest() -> Bool {
        let recorder = Recorder()
        var failure = false
        recorder.onFailure = { _ in failure = true }
        do {
            try recorder.start()
            defer { recorder.discard() }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            let before = recorder.writtenFrames
            recorder.engine.stop()
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            let after = recorder.writtenFrames
            guard let result = recorder.stop() else { return false }
            defer { try? FileManager.default.removeItem(at: result.url) }
            let file = try AVAudioFile(forReading: result.url)
            let ok = !failure && before > 0 && after > before && file.length == after
            print("通常録音の実機再接続: before=\(before) after=\(after) file=\(file.length) result=\(ok)")
            return ok
        } catch { print("FAIL: " + error.localizedDescription); return false }
    }

    private static func builtInInput() -> AudioDeviceID? {
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { device in
            var transport = UInt32(0), bytes = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, &transport) == noErr, transport == kAudioDeviceTransportTypeBuiltIn else { return false }
            address.mSelector = kAudioDevicePropertyStreams; address.mScope = kAudioDevicePropertyScopeInput
            return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &bytes) == noErr && bytes > 0
        }
    }
}
