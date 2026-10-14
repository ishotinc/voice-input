import Foundation
import AVFoundation

enum LiveDictationTests {
    static func run() -> Bool {
        var passed = true
        func check(_ name: String, _ good: Bool) { print((good ? "PASS: " : "FAIL: ") + name); passed = passed && good }
        check("固有名詞の異常な連続反復を検知", Transcriber.hasRunawayRepetition("固有名詞・" + String(repeating: "小野、", count: 70) + "だと思った"))
        check("通常の名前の繰返しは維持", !Transcriber.hasRunawayRepetition("小野さんと小野さんに確認します。"))
        let samples = Array(repeating: Float(0.1), count: 48000) + Array(repeating: Float(0), count: 10000)
            + Array(repeating: Float(0.2), count: 33333)
        var segmenter = SpeechSegments(), chunks: [[Float]] = []
        for offset in stride(from: 0, to: samples.count, by: 1371) {
            chunks += segmenter.append(Array(samples[offset..<min(offset + 1371, samples.count)]))
        }
        chunks.append(segmenter.finish())
        check("PCMを無音で区切ってもフレーム欠落・重複ゼロ", chunks.count >= 2 && chunks.flatMap { $0 } == samples)
        check("長い連続発話は途中で強制分割しない", {
            var splitter = SpeechSegments(); return splitter.append(Array(repeating: 0.1, count: 160000)).isEmpty && splitter.finish().count == 160000
        }())
        check("200msの息継ぎで停止前に区切る", {
            var splitter = SpeechSegments()
            return splitter.append(Array(repeating: 0.1, count: 40000) + Array(repeating: 0, count: 3200)).count == 1
        }())
        check("仮認識用スナップショットはPCMを消費しない", {
            var splitter = SpeechSegments(); let pcm = Array(repeating: Float(0.1), count: 70001)
            _ = splitter.append(pcm)
            return splitter.snapshot == pcm && splitter.snapshot == splitter.finish()
        }())
        check("仮認識後の無音だけなら再利用", LiveDictation.reusablePreview([0.1, 0.2], final: [0.1, 0.2, 0, 0]))
        check("仮認識後の追加発話は再認識", !LiveDictation.reusablePreview([0.1, 0.2], final: [0.1, 0.2, 0.1]))
        check("別の音声区間には仮認識を流用しない", !LiveDictation.reusablePreview([0.1, 0.2], final: [0.2, 0.1, 0]))
        let shortStarted = DispatchSemaphore(value: 0)
        let short = EarlyPolisher { text, _, _ in shortStarted.signal(); return text }
        short.offer("広告の制作費を確認します。")
        check("短い1文も停止前に校正を開始", shortStarted.wait(timeout: .now() + 1) == .success)
        short.cancel()
        check("WAVのヘッダとPCM長", SpeechSegments.wav([0, 0.5, -0.5]).count == 50)
        final class Calls { let lock = NSLock(); var count = 0; func increment() { lock.lock(); count += 1; lock.unlock() } }
        let calls = Calls()
        let early = EarlyPolisher { text, _, _ in calls.increment(); return text }
        let sentence = "明日の会議で使用する資料の担当者と会社名の表記を確認してください。"
        let full = sentence + "会議で確認する内容を順番に整理して、必要な資料が揃っているかどうかも確認してください。" + "確認が終わったら、その結果とまだ準備が必要な内容について、わかりやすくまとめてください。"
        early.offer(full)
        Thread.sleep(forTimeInterval: 0.05)
        check("AI starts before finish", calls.count == EarlyPolisher.plans(full).count)
        do {
            let output = try early.finish(full) { _, _ in }
            check("録音中の補正を最終文に再利用", calls.count == EarlyPolisher.plans(full).count && output.replacingOccurrences(of: "\n", with: "") == full)
            let changed = full.replacingOccurrences(of: "明日の会議", with: "来週の会議")
            let revised = try early.finish(changed) { _, _ in }
            check("後で変更された文は古い補正を使わない", revised.contains("来週の会議") && !revised.contains("明日の会議"))
        } catch { check("先行AI補正", false) }
        early.cancel()
        let failed = EarlyPolisher { _, _, _ in throw Polisher.PolishError.badResponse }
        do { _ = try failed.finish(full) { _, _ in }; check("先行AIが失敗したら未補正文を返さない", false) }
        catch { check("先行AIが失敗したら未補正文を返さない", true) }
        failed.cancel()
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try Polisher.runCLI(path: "/bin/sleep", arguments: ["5"], timeout: .infinity, stage: "cancel-test",
                cancelled: { ProcessInfo.processInfo.systemUptime - start > 0.05 })
            check("unused request cancellation", false)
        } catch Polisher.PolishError.cancelled {
            check("unused request cancellation", ProcessInfo.processInfo.systemUptime - start < 2)
        } catch { check("unused request cancellation", false) }
        return passed
    }
    static func replay(audio: URL, fastMode: Bool = true, withAI: Bool = false) -> Bool {
        do {
            let file = try AVAudioFile(forReading: audio, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return false }
            try file.read(into: buffer)
            let voice = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            let samples = voice + Array(repeating: Float(0), count: 12000) + voice + Array(repeating: Float(0), count: 12000)
            var settings = Settings.load(); settings.polishWithClaude = !fastMode
            if withAI { settings.selectedClientFolder = "" }
            ResidentTranscriber.warm(modelPath: settings.resolvedModel)
            defer { ResidentTranscriber.shutdown() }
            let live = LiveDictation(settings: settings, preparation: ReferencePreparation(folder: settings.selectedClientFolder, cachedOnly: fastMode), context: nil, allowsAI: withAI)
            defer { live.cancel() }
            for offset in stride(from: 0, to: samples.count, by: 3200) {
                let end = min(offset + 3200, samples.count)
                live.append(Array(samples[offset..<end]))
                Thread.sleep(forTimeInterval: Double(end - offset) / 16000)
            }
            let stopped = ProcessInfo.processInfo.systemUptime
            let output = try live.finish()
            let seconds = ProcessInfo.processInfo.systemUptime - stopped
            if withAI {
                _ = try live.polish(output, client: nil, progress: { _, _ in })
                print(String(format: "停止後AI完了まで %.3f秒（実Jev・Claude、架空文）", ProcessInfo.processInfo.systemUptime - stopped))
            }
            let occurrences = output.components(separatedBy: "確認").count - 1
            print(String(format: "録音相当 %.2f秒 / 停止後待ち %.3f秒 / 確認の出現 %d回", Double(samples.count) / 16000, seconds, occurrences))
            print(occurrences == 2 ? "PASS: 録音中に認識して同じ2文を抜け・重複なく結合" : "FAIL: 区間の結合を確認")
            return occurrences == 2
        } catch { print("FAIL: live transcription \(error)"); return false }
    }
}
