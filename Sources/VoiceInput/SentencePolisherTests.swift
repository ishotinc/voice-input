import Foundation

enum SentencePolisherTests {
    static func run() -> Bool {
        var passed = true
        func check(_ title: String, _ value: Bool) { print((value ? "PASS: " : "FAIL: ") + title); passed = passed && value }
        check("日本語の文末と改行で分割", SentencePolisher.split("一文目です。次です！\n最後です") == ["一文目です。", "次です！", "最後です"])
        check("引用内の句点で割らない", SentencePolisher.split("「確認です。続けます。」と伝える。次です。") == ["「確認です。続けます。」と伝える。", "次です。"])
        check("URL・小数点を壊さない", SentencePolisher.split("https://example.com/a?b=1と4.5を確認。次です。") == ["https://example.com/a?b=1と4.5を確認。", "次です。"])
        check("コードを分割しない", SentencePolisher.split("`x。y`を確認。次です。").count == 1)
        final class Counter {
            let lock = NSLock(); var active = 0; var peak = 0
            func enter() { lock.lock(); active += 1; peak = max(peak, active); lock.unlock() }
            func leave() { lock.lock(); active -= 1; lock.unlock() }
        }
        let counter = Counter()
        do {
            let output = try SentencePolisher.map(["0", "1", "2", "3", "4"], concurrency: 3) { index, value in
                counter.enter(); defer { counter.leave() }
                Thread.sleep(forTimeInterval: index == 0 ? 0.08 : 0.02)
                return value
            }
            check("実際に並列実行し上限3を守る", counter.peak > 1 && counter.peak <= 3)
            check("完了順が違っても元の文順を維持", output == ["0", "1", "2", "3", "4"])
        } catch { check("並列補正", false) }
        do {
            _ = try SentencePolisher.map(["a", "b", "c"]) { index, value in
                if index == 1 { throw Polisher.PolishError.timedOut }; return value
            }
            check("一文でも失敗したら部分結果を返さない", false)
        } catch { check("一文でも失敗したら部分結果を返さない", true) }
        do {
            _ = try SentencePolisher.map(["a"]) { _, _ in "" }
            check("空の補正結果を採用しない", false)
        } catch { check("空の補正結果を採用しない", true) }
        let payload = try? Polisher.userPayload(text: "今回の文", context: nil, neighboringSpeech: "前後の文")
        check("前後の文を発話対象と区別して渡す", payload?.contains("untrusted_neighboring_speech") == true)
        return passed
    }
}
