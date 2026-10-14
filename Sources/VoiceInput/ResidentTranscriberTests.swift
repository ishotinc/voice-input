import Foundation

struct ResidentTranscriberTests {
    static func run() -> Bool {
        let normal = String(decoding: ResidentTranscriber.multipart(audio: Data("RIFFfixture".utf8), boundary: "fixture", language: "ja", prompt: "UTAGE", fastMode: false), as: UTF8.self)
        let fast = String(decoding: ResidentTranscriber.multipart(audio: Data("RIFFfixture".utf8), boundary: "fixture", language: "ja", prompt: "UTAGE", fastMode: true), as: UTF8.self)
        let passed = normal.contains("name=\"file\"; filename=\"audio.wav\"") && normal.contains("RIFFfixture") && normal.contains("name=\"language\"\r\n\r\nja") && fast.contains("name=\"beam_size\"\r\n\r\n1") && fast.contains("name=\"temperature_inc\"\r\n\r\n0") && normal.contains("name=\"temperature_inc\"\r\n\r\n0.2") && !fast.contains("no_fallback")
        print(passed ? "PASS: 常駐認識のmultipartと対応済み高速設定" : "FAIL: 常駐認識のmultipart")
        return passed
    }
    static func run(audio: URL, modelPath: URL) -> Bool {
        defer { ResidentTranscriber.shutdown() }
        do {
            let coldStart = ProcessInfo.processInfo.systemUptime
            let first = try ResidentTranscriber.transcribe(audio: audio, modelPath: modelPath, language: "ja", prompt: "明日、設定、確認", fastMode: false)
            let cold = ProcessInfo.processInfo.systemUptime - coldStart
            let warmStart = ProcessInfo.processInfo.systemUptime
            let second = try ResidentTranscriber.transcribe(audio: audio, modelPath: modelPath, language: "ja", prompt: "明日、設定、確認", fastMode: false)
            let warm = ProcessInfo.processInfo.systemUptime - warmStart
            let fastStart = ProcessInfo.processInfo.systemUptime
            let fast = try ResidentTranscriber.transcribe(audio: audio, modelPath: modelPath, language: "ja", prompt: "", fastMode: true)
            let fastTime = ProcessInfo.processInfo.systemUptime - fastStart
            print(String(format: "Cold %.2fs / warm %.2fs / fast %.2fs", cold, warm, fastTime))
            print(first)
            print(second)
            print(fast)
            let passed = first.contains("明日") && first.contains("確認") && second.contains("明日") && second.contains("確認") && fast.contains("明日") && fast.contains("確認")
            print(passed ? "PASS: 日本語の常駐モデル初回と再利用" : "FAIL: 合成日本語の結果を確認")
            return passed
        } catch {
            print("FAIL: 常駐認識 \(error)")
            return false
        }
    }
}
