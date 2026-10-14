import Foundation
import Darwin

/// One owned loopback server; model and inference requests are serialized for the app lifetime.
final class ResidentTranscriber {
    private static let shared = ResidentTranscriber()
    private static let mlxShared = ResidentTranscriber(useMLX: true)
    private let useMLX: Bool
    private init(useMLX: Bool = false) { self.useMLX = useMLX }
    private let queue = DispatchQueue(label: "com.ishot.voice-input.whisper-resident")
    private let stateLock = NSLock()
    private var process: Process?
    private var model: String = ""
    private var baseURL: URL?
    private var childPID: Int32 = 0
    private var stopping = false

    enum ResidentError: Error { case unavailable, startup, response, tooLarge }
    static var serverPath: String? {
        ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func warm(modelPath: URL, useMLX: Bool = false) {
        let shared = useMLX ? mlxShared : Self.shared
        shared.queue.async { do { try shared.start(modelPath: modelPath) } catch { Log.write("whisper常駐準備失敗（次回は再試行／CLI）") } }
    }
    static func shutdown() { shared.stop(permanent: true); mlxShared.stop(permanent: true) }
    static func transcribe(audio: URL, modelPath: URL, language: String, prompt: String, fastMode: Bool, useMLX: Bool = false) throws -> String {
        let shared = useMLX ? mlxShared : Self.shared
        return try shared.queue.sync {
            try shared.start(modelPath: modelPath)
            let started = ProcessInfo.processInfo.systemUptime
            defer { Log.write(String(format: "\(useMLX ? "MLX" : "whisper")常駐 推論 %.2f秒", ProcessInfo.processInfo.systemUptime - started)) }
            guard let base = shared.baseURL, let port = base.port, shared.isAlive, shared.ownsPort(UInt16(port)) else { throw ResidentError.unavailable }
            let size = (try audio.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size > 0 && size <= 64_000_000 else { throw ResidentError.tooLarge }
            let boundary = "VoiceInput-" + UUID().uuidString
            let body = multipart(audio: try Data(contentsOf: audio), boundary: boundary, language: language, prompt: prompt, fastMode: fastMode)
            var request = URLRequest(url: base.appendingPathComponent("inference"))
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            do {
                let data = try shared.request(request, timeout: 600)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let text = json["text"] as? String else { throw ResidentError.response }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch { shared.stop(permanent: false); throw error }
        }
    }
    static func multipart(audio: Data, boundary: String, language: String, prompt: String, fastMode: Bool) -> Data {
        var body = Data()
        let fields = ["language": language, "prompt": String(prompt.prefix(2000)), "response_format": "json",
                      "no_timestamps": "true", "suppress_nst": "true", "best_of": fastMode ? "1" : "2",
                      "beam_size": fastMode ? "1" : "5", "temperature": "0", "temperature_inc": fastMode ? "0" : "0.2"]
        for key in fields.keys.sorted() {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(fields[key]!)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
    private var isAlive: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return !stopping && process?.isRunning == true
    }
    private func stop(permanent: Bool) {
        stateLock.lock()
        if permanent { stopping = true }
        let owned = process, pid = childPID
        process = nil; childPID = 0
        stateLock.unlock()
        // Signal only the child launched by this guardian, and the guardian itself.
        if let owned, owned.isRunning {
            if pid > 0 { Darwin.kill(pid, SIGTERM) }
            owned.terminate()
            let deadline = Date().addingTimeInterval(2)
            while owned.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if owned.isRunning {
                if pid > 0 { Darwin.kill(pid, SIGKILL) }
                Darwin.kill(owned.processIdentifier, SIGKILL)
            }
        }
    }
    private static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ResidentError.startup }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw ResidentError.startup }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard result == 0 else { throw ResidentError.startup }
        return UInt16(bigEndian: address.sin_port)
    }
    private func start(modelPath: URL) throws {
        if model == modelPath.path && isAlive, baseURL != nil { return }
        stateLock.lock(); let halted = stopping; stateLock.unlock()
        guard !halted else { throw ResidentError.unavailable }
        let executable: String
        if useMLX {
            executable = NSHomeDirectory() + "/.voice-input/mlx-runtime/bin/python"
            guard FileManager.default.isExecutableFile(atPath: executable) else { throw ResidentError.unavailable }
        } else {
            guard let path = Self.serverPath else { throw ResidentError.unavailable }
            executable = path
        }
        stop(permanent: false)
        let started = ProcessInfo.processInfo.systemUptime
        let port = try Self.freePort()
        let prefix = "/" + UUID().uuidString
        let owned = Process()
        owned.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The guardian kills its child if the app exits, including unexpected app termination.
        let guardian = "parent=$1; shift; child=; trap 'if [ -n \"$child\" ]; then kill -TERM \"$child\" 2>/dev/null; wait \"$child\"; fi; exit' TERM INT HUP; \"$@\" & child=$!; echo VOICE_SERVER_PID=$child; while kill -0 \"$parent\" 2>/dev/null && kill -0 \"$child\" 2>/dev/null; do sleep 1; done; kill -TERM \"$child\" 2>/dev/null; wait \"$child\""
        owned.arguments = ["-c", guardian, "voice-input-guardian", String(ProcessInfo.processInfo.processIdentifier), executable,
                           "-m", modelPath.path, "--host", "127.0.0.1", "--port", String(port), "--request-path", prefix,
                           "--public", "/dev/null", "-l", "ja", "-sns", "-nt", "-t", "4"]
        if useMLX {
            guard let helper = Bundle.main.url(forResource: "mlx-server", withExtension: "py") else { throw ResidentError.unavailable }
            owned.arguments = ["-c", guardian, "voice-input-guardian", String(ProcessInfo.processInfo.processIdentifier), executable,
                helper.path, "--port", String(port), "--prefix", prefix,
                "--model", NSHomeDirectory() + "/.voice-input/mlx-models/large-v3-turbo"]
            var environment = ProcessInfo.processInfo.environment
            environment["HF_HUB_OFFLINE"] = "1"; environment["TOKENIZERS_PARALLELISM"] = "false"
            owned.environment = environment
        }
        let output = Pipe(), errors = Pipe()
        owned.standardOutput = output; owned.standardError = errors; owned.standardInput = FileHandle.nullDevice
        stateLock.lock()
        guard !stopping else { stateLock.unlock(); throw ResidentError.unavailable }
        process = owned
        do { try owned.run() } catch { process = nil; stateLock.unlock(); throw error }
        stateLock.unlock()
        // Never retain server logs: they may contain recognized speech.
        DispatchQueue.global().async { while !errors.fileHandleForReading.availableData.isEmpty {} }
        DispatchQueue.global().async { [weak self] in
            var pending = Data()
            while true {
                let bytes = output.fileHandleForReading.availableData
                if bytes.isEmpty { break }
                pending.append(bytes)
                while let newline = pending.firstIndex(of: 10) {
                    let line = String(decoding: pending[..<newline], as: UTF8.self)
                    pending.removeSubrange(...newline)
                    if line.hasPrefix("VOICE_SERVER_PID="), let pid = Int32(line.dropFirst(17)) {
                        self?.stateLock.lock(); if self?.process === owned { self?.childPID = pid }; self?.stateLock.unlock()
                    }
                }
                if pending.count > 8192 { pending.removeAll() }
            }
        }
        let base = URL(string: "http://127.0.0.1:\(port)\(prefix)")!
        let deadline = Date().addingTimeInterval(useMLX ? 120 : 60)
        while isAlive && Date() < deadline {
            if ownsPort(port), let data = try? request(URLRequest(url: base.appendingPathComponent("health")), timeout: 0.5),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: String], json["status"] == "ok" {
                // UUID route plus our still-live guardian ensure no generic foreign service is reused.
                model = modelPath.path; baseURL = base
                Log.write(String(format: "\(useMLX ? "MLX" : "whisper")常駐 モデル準備 %.2f秒", ProcessInfo.processInfo.systemUptime - started))
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        stop(permanent: false)
        throw ResidentError.startup
    }
    private func ownsPort(_ port: UInt16) -> Bool {
        stateLock.lock(); let pid = childPID; stateLock.unlock()
        guard pid > 0, isAlive else { return false }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        check.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP:" + String(port), "-sTCP:LISTEN", "-F", "p"]
        let pipe = Pipe(); check.standardOutput = pipe; check.standardError = FileHandle.nullDevice
        guard (try? check.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); check.waitUntilExit()
        return check.terminationStatus == 0 && String(decoding: data, as: UTF8.self).split(separator: "\n").contains(Substring("p" + String(pid)))
    }
    private func request(_ input: URLRequest, timeout: TimeInterval) throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = input
        request.timeoutInterval = timeout
        final class Response: @unchecked Sendable { var data: Data?; var error: Error?; var status = 0 }
        let response = Response(), ended = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, answer, error in
            response.data = data; response.error = error; response.status = (answer as? HTTPURLResponse)?.statusCode ?? 0
            ended.signal()
        }.resume()
        guard ended.wait(timeout: .now() + timeout + 1) == .success else { throw ResidentError.response }
        if let error = response.error { throw error }
        guard response.status == 200, let data = response.data, data.count <= 2_000_000 else { throw ResidentError.response }
        return data
    }
}
