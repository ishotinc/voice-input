import Foundation

/// whisper.cpp をローカルで呼ぶ。音声は外に出さない。
struct Transcriber {
    var whisperPath: String
    var modelPath: URL
    var language: String
    var initialPrompt: String
    var fastMode: Bool = false
    var useMLX: Bool = false

    enum TranscribeError: LocalizedError {
        case whisperMissing
        case modelMissing(String)
        case failed(Int32, String)

        var errorDescription: String? {
            switch self {
            case .whisperMissing:
                return "whisper-cli が見つかりません。`brew install whisper-cpp` を実行してください。"
            case .modelMissing(let p):
                return "モデルがありません: \(p)"
            case .failed(let code, let err):
                return "文字起こしに失敗しました（終了コード \(code)）: \(err)"
            }
        }
    }

    static func hasRunawayRepetition(_ text: String) -> Bool {
        text.range(of: #"(.{1,24}?)\1{7,}"#, options: .regularExpression) != nil
    }
    func transcribe(_ audio: URL) throws -> String {
        let text = try recognize(audio)
        guard Self.hasRunawayRepetition(text) else { return text }
        Log.write("異常反復を検出: ヒントなし・精度設定で同じ音声を再認識")
        var retry = self; retry.initialPrompt = ""; retry.fastMode = false; retry.useMLX = false
        let repaired = try retry.recognize(audio)
        guard !repaired.isEmpty, !Self.hasRunawayRepetition(repaired) else {
            throw TranscribeError.failed(-1, "同じ語の異常な反復が再認識でも解消しませんでした。")
        }
        return repaired
    }
    private func recognize(_ audio: URL) throws -> String {
        if useMLX {
            do {
                return try ResidentTranscriber.transcribe(audio: audio, modelPath: modelPath, language: language,
                    prompt: initialPrompt, fastMode: fastMode, useMLX: true)
            } catch { Log.write("MLX認識失敗: 保存済み音声をwhisper.cppで再試行") }
        }
        guard FileManager.default.isExecutableFile(atPath: whisperPath) else {
            throw TranscribeError.whisperMissing
        }
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw TranscribeError.modelMissing(modelPath.path)
        }

        do {
            return try ResidentTranscriber.transcribe(audio: audio, modelPath: modelPath, language: language,
                                                      prompt: initialPrompt, fastMode: fastMode)
        } catch { Log.write("whisper常駐を使えないためCLIで変換") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        var args = [
            "-m", modelPath.path,
            "-f", audio.path,
            "-l", language,
            "-t", String(max(4, ProcessInfo.processInfo.activeProcessorCount - 2)),
            "-nt", "-np",
            "-sns",                       // 「(咳)」等の非発話トークンを出させない
        ]
        if fastMode { args.append(contentsOf: ["-bs", "1", "-bo", "1", "-nf"]) }
        if !initialPrompt.isEmpty {
            args.append(contentsOf: ["--prompt", initialPrompt])
        }
        process.arguments = args

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let started = Date()
        try process.run()
        final class Output: @unchecked Sendable { var data = Data() }
        let stdout = Output(), stderr = Output(), drained = DispatchGroup()
        for (pipe, target) in [(outPipe, stdout), (errPipe, stderr)] {
            drained.enter()
            DispatchQueue.global().async {
                defer { drained.leave() }
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    if target.data.count < 2_000_000 { target.data.append(chunk.prefix(2_000_000 - target.data.count)) }
                }
            }
        }
        process.waitUntilExit()
        drained.wait()
        let outData = stdout.data, errData = stderr.data
        Log.write(String(format: "whisper %.1f秒 exit=%d", Date().timeIntervalSince(started), process.terminationStatus))

        let stderrText = String(data: errData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw TranscribeError.failed(process.terminationStatus, stderrText.suffix(400).description)
        }

        return (String(data: outData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
