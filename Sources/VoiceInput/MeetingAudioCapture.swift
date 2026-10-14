import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// One explicitly started meeting. Only the selected browser's audio is captured; video is never saved.
/// Call start/stop from one owner. Callbacks run on the serial callback queue, never an audio tap.
/// Completed files deliberately survive stop/errors for retry and later user-confirmed deletion.
final class MeetingAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Channel: String, Codable { case local, remote }
    struct Chunk: Codable {
        let url: URL
        let channel: Channel
        let startSeconds: Double
        let durationSeconds: Double
    }
    enum CaptureError: LocalizedError {
        case browserUnavailable, displayUnavailable, microphoneDenied, noMicrophone, microphoneChanged
        case conversionFailed, overloaded, alreadyStarted, cancelled
        var errorDescription: String? {
            switch self {
            case .browserUnavailable: return "選択したブラウザが見つかりません。Google Meetを開き直してください。"
            case .displayUnavailable: return "会議音声の取得先が見つかりません。画面収録の許可を確認してください。"
            case .microphoneDenied: return "会議録音にはマイクの許可が必要です。"
            case .noMicrophone: return "マイクの入力形式を取得できませんでした。"
            case .microphoneChanged: return "マイクの接続変更後、8回再試行しても復旧できず録音を停止しました。保存済み音声は保持しています。"
            case .conversionFailed: return "会議音声の変換に失敗しました。保存済みの音声は残しています。"
            case .overloaded: return "会議音声の保存が追いつかなくなりました。保存済みの音声は残しています。"
            case .alreadyStarted: return "会議録音はすでに開始されています。"
            case .cancelled: return "会議録音の開始を中止しました。"
            }
        }
    }

    private let directory: URL
    private let browserPID: pid_t
    private let chunkSeconds: Double
    private let onChunk: (Chunk) -> Void
    private let onError: (Error) -> Void
    private let audioQueue = DispatchQueue(label: "voiceinput.meeting.audio", qos: .userInitiated)
    private let callbackQueue = DispatchQueue(label: "voiceinput.meeting.callbacks")
    private let pendingMic = DispatchSemaphore(value: 32)
    private let stateLock = NSLock()
    private var accepting = false
    private var attempted = false
    private var remoteAccepting = false
    private var configurationObserver: NSObjectProtocol?
    private var didReportError = false
    private var firstError: Error?
    @MainActor private var stopTask: Task<[Chunk], Never>?
    @MainActor private var stopRequested = false
    @MainActor private var microphoneRecovery: Task<Void, Never>?
    @MainActor private var microphoneGeneration = UUID()
    private var stream: SCStream?
    private var engine: AVAudioEngine?
    private var microphoneTapInstalled = false
    private var localWriter: ChunkWriter?
    private var remoteWriter: ChunkWriter?
    private var microphoneConverter: AVAudioConverter?
    private var remoteConverter: AVAudioConverter?
    private var remoteFormat: AVAudioFormat?
    private var startedUptime: Double = 0
    private(set) var recordingStartedAt: Date?
    private var finished: [Chunk] = []
    private static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                               channels: 1, interleaved: false)!

    init(directory: URL, browserPID: pid_t, chunkSeconds: Double = 25,
         onChunk: @escaping (Chunk) -> Void, onError: @escaping (Error) -> Void) {
        self.directory = directory
        self.browserPID = browserPID
        self.chunkSeconds = max(5, min(60, chunkSeconds))
        self.onChunk = onChunk
        self.onError = onError
        super.init()
    }

    /// Must only be called in response to the user's Start Meeting command.
    /// This is the only place that asks macOS for microphone / screen-audio permission.
    @MainActor func start() async throws {
        guard !stopRequested else { throw CaptureError.cancelled }
        guard !attempted else { throw CaptureError.alreadyStarted }
        attempted = true
        let microphoneAllowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphoneAllowed = true
        case .notDetermined: microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: microphoneAllowed = false
        }
        guard !stopRequested else { throw CaptureError.cancelled }
        guard microphoneAllowed else { throw CaptureError.microphoneDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !stopRequested else { throw CaptureError.cancelled }
        guard let browser = content.applications.first(where: { $0.processID == browserPID }) else {
            throw CaptureError.browserUnavailable
        }
        guard let display = content.displays.first else { throw CaptureError.displayUnavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let filter = SCContentFilter(display: display, including: [browser], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16_000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        config.queueDepth = 3
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        recordingStartedAt = Date()
        startedUptime = ProcessInfo.processInfo.systemUptime
        localWriter = ChunkWriter(directory: directory, channel: .local, seconds: chunkSeconds,
                                  completed: { [weak self] in self?.completed($0) })
        remoteWriter = ChunkWriter(directory: directory, channel: .remote, seconds: chunkSeconds,
                                   completed: { [weak self] in self?.completed($0) })
        setAccepting(true)
        remoteAccepting = true
        stream = capture
        do {
            // Start browser capture before microphone activation can switch a Bluetooth audio route.
            do { try await capture.startCapture() } catch {
                let e = error as NSError
                Log.write("会議ブラウザ音声開始失敗: \(e.domain) code=\(e.code)")
                throw error
            }
            try await startMicrophoneWithRetry()
            if let error = reportedError { throw error }
            if stopRequested { throw CaptureError.cancelled }
        } catch {
            _ = await stop()
            throw error
        }
    }

    /// Rebuild only the microphone when Bluetooth / Meet changes the default audio route.
    /// Browser capture and the meeting clock keep running throughout recovery.
    @MainActor private func detachMicrophone() {
        microphoneGeneration = UUID()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine {
            if microphoneTapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
        microphoneTapInstalled = false
        engine = nil
    }

    @MainActor private func startMicrophoneWithRetry() async throws {
        var lastError: Error = CaptureError.noMicrophone
        for attempt in 0..<8 {
            guard !stopRequested, !Task.isCancelled else { throw CaptureError.cancelled }
            detachMicrophone()
            do {
                try installMicrophone()
                return
            } catch {
                lastError = error
                detachMicrophone()
                Log.write("会議マイク再接続 \(attempt + 1)/8: \(error.localizedDescription)")
                if attempt < 7 { try await Task.sleep(nanoseconds: 500_000_000) }
            }
        }
        throw lastError
    }

    @MainActor private func installMicrophone() throws {
        let mic = AVAudioEngine()
        let input = mic.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noMicrophone }
        guard let converter = AVAudioConverter(from: format, to: Self.target) else { throw CaptureError.conversionFailed }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self, self.isAccepting else { return }
            // Bound queued buffers. Never wait on the real-time audio callback.
            guard self.pendingMic.wait(timeout: .now()) == .success else {
                self.fail(CaptureError.overloaded)
                return
            }
            guard let copy = Self.copy(buffer) else {
                self.pendingMic.signal(); self.fail(CaptureError.conversionFailed); return
            }
            let position = when.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: when.hostTime) - self.startedUptime
                : ProcessInfo.processInfo.systemUptime - self.startedUptime - Double(buffer.frameLength) / format.sampleRate
            self.audioQueue.async {
                defer { self.pendingMic.signal() }
                do {
                    let converted = try Self.convert(copy, using: converter)
                    try self.localWriter?.append(converted, at: max(0, position))
                } catch { self.fail(error) }
            }
        }
        microphoneTapInstalled = true
        engine = mic
        mic.prepare()
        try mic.start()
        let generation = microphoneGeneration
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: mic, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.microphoneConfigurationChanged(generation: generation, sampleRate: format.sampleRate, channels: format.channelCount)
            }
        }
        Log.write("会議マイク接続: \(format.sampleRate)Hz/\(format.channelCount)ch running=\(mic.isRunning)")
    }

    @MainActor private func microphoneConfigurationChanged(generation: UUID, sampleRate: Double, channels: AVAudioChannelCount) {
        guard generation == microphoneGeneration, !stopRequested, isAccepting,
              microphoneRecovery == nil, let engine else { return }
        let current = engine.inputNode.outputFormat(forBus: 0)
        guard !engine.isRunning || current.sampleRate != sampleRate || current.channelCount != channels else { return }
        Log.write("会議マイク構成変更: \(current.sampleRate)Hz/\(current.channelCount)ch running=\(engine.isRunning)、会議を止めず再接続")
        detachMicrophone()
        microphoneRecovery = Task { @MainActor in
            defer { microphoneRecovery = nil }
            do {
                // Give the OS time to settle a Bluetooth profile change.
                try await Task.sleep(nanoseconds: 300_000_000)
                try await startMicrophoneWithRetry()
                Log.write("会議マイク再接続完了: 録音を継続")
            } catch {
                if !stopRequested && !Task.isCancelled { fail(CaptureError.microphoneChanged) }
            }
        }
    }

    /// Opt-in hardware regression: real microphone buffers before/after an engine-stop notification.
    /// No Meet session, AI request or cloud upload; temporary audio is removed after validation.
    @MainActor static func runMicrophoneRecoveryTest() async -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("FAIL: この実行元にマイク権限がありません"); return false
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voiceinput-mic-test-" + UUID().uuidString)
        let capture = MeetingAudioCapture(directory: directory, browserPID: 0, onChunk: { _ in }, onError: { _ in })
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            capture.startedUptime = ProcessInfo.processInfo.systemUptime
            capture.localWriter = ChunkWriter(directory: directory, channel: .local, seconds: 25, completed: { capture.completed($0) })
            capture.setAccepting(true)
            try await capture.startMicrophoneWithRetry()
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let boundary = ProcessInfo.processInfo.systemUptime - capture.startedUptime
            let previous = capture.engine!
            previous.stop()
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: previous)
            try await Task.sleep(nanoseconds: 2_500_000_000)
            guard capture.engine !== previous, capture.engine?.isRunning == true, capture.reportedError == nil else {
                _ = await capture.stop(); print("FAIL: マイク再接続"); return false
            }
            // Stop while a second recovery is pending: it must never restart after meeting exit.
            capture.engine!.stop()
            capture.microphoneConfigurationChanged(generation: capture.microphoneGeneration, sampleRate: 0, channels: 0)
            let chunks = await capture.stop()
            try await Task.sleep(nanoseconds: 500_000_000)
            guard capture.engine == nil, capture.microphoneRecovery == nil, capture.reportedError == nil,
                  chunks.contains(where: { $0.startSeconds < boundary && $0.durationSeconds > 0.2 }),
                  chunks.contains(where: { $0.startSeconds + $0.durationSeconds > boundary + 1 }) else {
                print("FAIL: 再接続後PCMまたは終了時キャンセル"); return false
            }
            print("PASS: 実マイク停止通知→再接続→PCM保存継続・復旧中の終了・停止後の再起動なし")
            return true
        } catch {
            _ = await capture.stop(); try? FileManager.default.removeItem(at: directory)
            print("FAIL: \(error.localizedDescription)"); return false
        }
    }

    /// Flushes both tails and returns every durable chunk. It never deletes meeting audio.
    /// onChunk callbacks have all finished when this method returns.
    @MainActor func stop() async -> [Chunk] {
        stopRequested = true
        if let stopTask { return await stopTask.value }
        let task = Task { await self.performStop() }
        stopTask = task
        return await task.value
    }
    @MainActor private func performStop() async -> [Chunk] {
        setAccepting(false)
        microphoneRecovery?.cancel()
        if let microphoneRecovery { await microphoneRecovery.value }
        detachMicrophone()
        if let stream {
            do { try await stream.stopCapture() }
            catch { fail(error) }
        }
        stream = nil
        return await withCheckedContinuation { continuation in
            audioQueue.async {
                self.remoteAccepting = false
                self.localWriter?.finish()
                self.remoteWriter?.finish()
                self.localWriter = nil
                self.remoteWriter = nil
                self.microphoneConverter = nil
                self.remoteConverter = nil
                let chunks = self.finished.sorted { $0.startSeconds < $1.startSeconds }
                self.callbackQueue.async { continuation.resume(returning: chunks) }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { fail(error) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, remoteAccepting,
              let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        do {
            if remoteFormat != format {
                remoteFormat = format
                remoteConverter = AVAudioConverter(from: format, to: Self.target)
            }
            guard let converter = remoteConverter else { throw CaptureError.conversionFailed }
            let list = AudioBufferList.allocate(maximumBuffers: max(1, Int(format.channelCount)))
            defer { free(list.unsafeMutablePointer) }
            var retained: CMBlockBuffer?
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,
                bufferListSizeNeededOut: nil, bufferListOut: list.unsafeMutablePointer,
                bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: list.count),
                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
                blockBufferOut: &retained)
            guard status == noErr, let input = AVAudioPCMBuffer(pcmFormat: format,
                bufferListNoCopy: list.unsafeMutablePointer, deallocator: nil) else {
                throw CaptureError.conversionFailed
            }
            input.frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
            let converted = try Self.convert(input, using: converter)
            // ScreenCaptureKit audio presentation time uses the host monotonic clock.
            let hostPosition = sampleBuffer.presentationTimeStamp.seconds - startedUptime
            let fallback = ProcessInfo.processInfo.systemUptime - startedUptime
                - Double(input.frameLength) / format.sampleRate
            let position = hostPosition.isFinite && hostPosition >= 0 ? hostPosition : max(0, fallback)
            try remoteWriter?.append(converted, at: position)
            withExtendedLifetime(retained) {}
        } catch { fail(error) }
    }

    private var isAccepting: Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return accepting
    }
    private func setAccepting(_ value: Bool) {
        stateLock.lock(); accepting = value; stateLock.unlock()
    }
    private var reportedError: Error? {
        stateLock.lock(); defer { stateLock.unlock() }; return firstError
    }
    private func fail(_ error: Error) {
        stateLock.lock()
        let report = !didReportError
        if report { firstError = error }
        didReportError = true
        accepting = false
        stateLock.unlock()
        if report { callbackQueue.async { self.onError(error) } }
    }
    private func completed(_ chunk: Chunk) {
        finished.append(chunk)
        do {
            // Independent of the recognition queue: quit/crash cannot orphan completed chunks
            // merely because speech recognition has not caught up with recording yet.
            try Self.persist(finished, in: directory)
            callbackQueue.async { self.onChunk(chunk) }
        } catch { fail(error) }
    }
    private struct PersistedChunk: Codable {
        let file: String
        let channel: Channel
        let start: Double
        let duration: Double
    }
    private static func persist(_ chunks: [Chunk], in directory: URL) throws {
        let entries = chunks.map { PersistedChunk(file: $0.url.lastPathComponent, channel: $0.channel,
                                                  start: $0.startSeconds, duration: $0.durationSeconds) }
        let manifest = directory.appendingPathComponent("capture-manifest.json")
        try JSONEncoder().encode(entries).write(to: manifest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
    }
    /// Recovery source independent from the main meeting/ASR manifest. Missing manifest means no completed chunks.
    static func loadPersistedChunks(directory: URL) throws -> [Chunk] {
        let manifest = directory.appendingPathComponent("capture-manifest.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        let entries = try JSONDecoder().decode([PersistedChunk].self, from: Data(contentsOf: manifest))
        return try entries.map { entry in
            guard entry.file == URL(fileURLWithPath: entry.file).lastPathComponent,
                  !entry.file.contains(".."), entry.file.hasSuffix(".wav"),
                  entry.start.isFinite, entry.start >= 0,
                  entry.duration.isFinite, entry.duration > 0 else { throw CaptureError.conversionFailed }
            let url = directory.appendingPathComponent(entry.file)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CaptureError.conversionFailed }
            return Chunk(url: url, channel: entry.channel, startSeconds: entry.start, durationSeconds: entry.duration)
        }
    }
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<source.count {
            guard let src = source[index].mData, let dst = destination[index].mData else { return nil }
            memcpy(dst, src, Int(source[index].mDataByteSize))
        }
        return copy
    }
    private static func convert(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(Double(input.frameLength) * 16_000 / input.format.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames) else { throw CaptureError.conversionFailed }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, result in
            if supplied { result.pointee = .noDataNow; return nil }
            supplied = true; result.pointee = .haveData; return input
        }
        guard status != .error else { throw error ?? CaptureError.conversionFailed as NSError }
        return output
    }

    /// Offline verification: no microphone, permissions, or real meeting data involved.
    static func runSelfTests() -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-capture-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var chunks: [Chunk] = []
            let writer = ChunkWriter(directory: directory, channel: .remote, seconds: 5) { chunks.append($0) }
            func append(frames: Int, at position: Double) throws {
                let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(frames))!
                buffer.frameLength = AVAudioFrameCount(frames)
                for index in 0..<frames { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.1)) * 0.1 }
                try writer.append(buffer, at: position)
            }
            try append(frames: 96_000, at: 2)
            try append(frames: 8_000, at: 8)
            try append(frames: 16_000, at: 12) // A real gap must not be collapsed.
            writer.finish()
            guard chunks.count == 3,
                  chunks.map(\.startSeconds) == [2, 7, 12],
                  chunks.map(\.durationSeconds) == [5, 1.5, 1] else { return false }
            var total: AVAudioFramePosition = 0
            for chunk in chunks {
                let file = try AVAudioFile(forReading: chunk.url)
                guard file.fileFormat.sampleRate == 16_000, file.fileFormat.channelCount == 1 else { return false }
                total += file.length
            }
            guard total == 120_000 else { return false }
            try persist(chunks, in: directory)
            let recovered = try loadPersistedChunks(directory: directory)
            guard recovered.map(\.url) == chunks.map(\.url), recovered.map(\.startSeconds) == [2, 7, 12] else { return false }
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("capture-manifest.json").path)
            guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { return false }
            let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
            let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_800)!
            input.frameLength = 4_800
            for channel in 0..<2 { input.floatChannelData![channel].initialize(repeating: 0.1, count: 4_800) }
            let clone = copy(input)!
            guard clone.floatChannelData![1][200] == 0.1 else { return false }
            let converter = AVAudioConverter(from: inputFormat, to: target)!
            let converted = try convert(clone, using: converter)
            guard converted.frameLength > 1_000, converted.frameLength <= 1_600 else { return false }
            print("Meeting audio: PCM conversion / chunk rotation / timestamps / discontinuity / durable WAV / recovery manifest: PASS")
            return true
        } catch {
            print("Meeting audio self-test failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Serial-queue-only writer, bounded to one PCM callback buffer and one open file per channel.
    private final class ChunkWriter {
        let directory: URL
        let channel: Channel
        let maximumFrames: Int
        let completed: (Chunk) -> Void
        var file: AVAudioFile?
        var url: URL?
        var frames = 0
        var start: Double = 0
        var expectedNext: Double?
        init(directory: URL, channel: Channel, seconds: Double, completed: @escaping (Chunk) -> Void) {
            self.directory = directory; self.channel = channel
            self.maximumFrames = Int(seconds * 16_000); self.completed = completed
        }
        func append(_ buffer: AVAudioPCMBuffer, at position: Double) throws {
            guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { return }
            // Preserve discontinuities as separate timestamped chunks, rather than compressing the gap.
            if let expectedNext, abs(position - expectedNext) > 0.4 { finish() }
            var offset = 0
            while offset < Int(buffer.frameLength) {
                if file == nil {
                    start = position + Double(offset) / 16_000
                    let path = directory.appendingPathComponent("\(channel.rawValue)-\(UUID().uuidString).wav")
                    file = try AVAudioFile(forWriting: path, settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0,
                        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
                    ], commonFormat: .pcmFormatFloat32, interleaved: false)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                    url = path
                }
                let count = min(maximumFrames - frames, Int(buffer.frameLength) - offset)
                guard let slice = AVAudioPCMBuffer(pcmFormat: MeetingAudioCapture.target, frameCapacity: AVAudioFrameCount(count)),
                      let destination = slice.floatChannelData?[0] else { throw CaptureError.conversionFailed }
                slice.frameLength = AVAudioFrameCount(count)
                destination.update(from: data.advanced(by: offset), count: count)
                try file?.write(from: slice)
                frames += count; offset += count
                if frames == maximumFrames { finish() }
            }
            expectedNext = position + Double(buffer.frameLength) / 16_000
        }
        func finish() {
            file = nil
            if let url, frames > 0 {
                completed(Chunk(url: url, channel: channel, startSeconds: start, durationSeconds: Double(frames) / 16_000))
            }
            url = nil; frames = 0; expectedNext = nil
        }
    }
}
