import Foundation

struct PolisherTests {
    static func run() -> Bool {
        final class Counts: @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
            var failures = 0
            func called() { lock.lock(); calls += 1; lock.unlock() }
            func failed() { lock.lock(); failures += 1; lock.unlock() }
        }
        enum TestError: Error { case rejected }
        var failed = 0
        func check(_ title: String, _ condition: Bool) {
            print((condition ? "PASS: " : "FAIL: ") + title)
            if !condition { failed += 1 }
        }
        let counts = Counts()
        let cache = Polisher.AuthenticationCache()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        cache.prepare {
            counts.called()
            entered.signal()
            guard release.wait(timeout: .now() + 3) == .success else { throw TestError.rejected }
        }
        let started = entered.wait(timeout: .now() + 2) == .success
        let done = DispatchGroup()
        for _ in 0..<6 {
            done.enter()
            DispatchQueue.global().async {
                defer { done.leave() }
                do { try cache.ensure(timeout: 3) { counts.called() } }
                catch { counts.failed() }
            }
        }
        release.signal()
        let completed = done.wait(timeout: .now() + 4) == .success
        counts.lock.lock()
        let single = counts.calls == 1 && counts.failures == 0
        counts.lock.unlock()
        check("録音中の認証と並列の仕上げ待ちで認証を1回だけ実行", started && completed && single)

        let rejected = Polisher.AuthenticationCache()
        var denied = false
        do { try rejected.ensure(timeout: 2) { throw TestError.rejected } }
        catch { denied = true }
        var deniedAgain = false
        do { try rejected.ensure(timeout: 2) {} }
        catch { deniedAgain = true }
        check("失敗を認証成功として扱わない", denied && deniedAgain)

        let expiring = Polisher.AuthenticationCache(lifetime: 0)
        let expiryCounts = Counts()
        do {
            try expiring.ensure(timeout: 2) { expiryCounts.called() }
            try expiring.ensure(timeout: 2) { expiryCounts.called() }
        } catch { expiryCounts.failed() }
        check("有効期限後は認証を再実行", expiryCounts.calls == 2 && expiryCounts.failures == 0)
        let success = #"{"type":"result","subtype":"success","is_error":false,"result":"整形後"}"#
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"合成テキスト"}}}"#
        let thinking = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"合成データ"}}}"#
        check("従来のJSON応答を維持", (try? Polisher.parseResult(Data(success.utf8))) == "整形後")
        check("ストリームは最終結果だけを採用", (try? Polisher.parseResult(Data((delta + "\n" + success + "\n").utf8))) == "整形後")
        check("途中までのストリームを貼り付けない", (try? Polisher.parseResult(Data((delta + "\n").utf8))) == nil)
        check("壊れた最終行を採用しない", (try? Polisher.parseResult(Data((delta + "\n{" ).utf8))) == nil)
        let truncated = #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}}"#
        check("ストリーム中の出力上限を検出", (try? Polisher.parseResult(Data((truncated + "\n" + success).utf8))) == nil)
        check("初回テキストと推論のイベント種別だけを識別", Polisher.streamTimingEvent(Data(delta.utf8)) == "text_delta" && Polisher.streamTimingEvent(Data(thinking.utf8)) == "thinking_delta" && Polisher.streamTimingEvent(Data(success.utf8)) == "result")
        check("無期限の待機を安全に表す", Polisher.waitDeadline(timeout: .infinity) == .distantFuture)
        do {
            let child = try Polisher.runCLI(path: "/bin/echo", arguments: ["synthetic-ok"], timeout: .infinity, stage: "無期限テスト")
            check("無期限でも子プロセスの正常終了で戻る", String(decoding: child, as: UTF8.self).contains("synthetic-ok"))
        } catch { check("無期限でも子プロセスの正常終了で戻る", false) }
        do {
            _ = try Polisher.runCLI(path: "/bin/sleep", arguments: ["1"], timeout: 0.02, stage: "有限期限テスト")
            check("明示された有限期限は有効", false)
        } catch Polisher.PolishError.timedOut { check("明示された有限期限は有効", true) }
        catch { check("明示された有限期限は有効", false) }
        do {
            _ = try Polisher.runCLI(path: "/usr/bin/false", arguments: [], timeout: .infinity, stage: "異常終了テスト")
            check("無期限でも異常終了はエラーになる", false)
        } catch { check("無期限でも異常終了はエラーになる", true) }
        return failed == 0
    }
}
