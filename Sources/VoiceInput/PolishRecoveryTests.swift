import Foundation

/// AI 補正の失敗からの立て直しを、偽の claude / codex コマンドで確かめる。実 API もキーチェーンも使わない。
enum PolishRecoveryTests {
    static func run() -> Bool {
        var passed = true
        func check(_ name: String, _ good: Bool) { print((good ? "PASS: " : "FAIL: ") + name); passed = passed && good }
        Log.testSkipsFile = true
        defer { Log.testSkipsFile = false }
        func error(_ body: () throws -> Any) -> Error? { do { _ = try body(); return nil } catch { return error } }
        func isLogin(_ error: Error?) -> Bool { if case .some(Polisher.PolishError.maxLoginRequired) = error { return true }; return false }

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("voice-recovery-" + UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func flag(_ name: String, _ value: String?) {
            let url = dir.appendingPathComponent(name)
            if let value { try? value.write(to: url, atomically: true, encoding: .utf8) } else { try? fm.removeItem(at: url) }
        }
        // 実測した claude 2.1.316 の出力の形をそのまま返す偽コマンド。
        let claude = dir.appendingPathComponent("claude"), codex = dir.appendingPathComponent("codex")
        let claudeScript = """
        #!/bin/bash
        D='\(dir.path)'
        if [ "$2" = auth ]; then
          if [ -f "$D/loggedout" ]; then echo '{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}'; exit 1; fi
          echo '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}'; exit 0
        fi
        cat >/dev/null
        echo x >> "$D/calls"
        n=$(cat "$D/bad" 2>/dev/null || echo 0)
        if [ "$n" -gt 0 ]; then echo $((n-1)) > "$D/bad"; echo 'not json'; exit 1; fi
        if [ -f "$D/expired" ]; then
          echo '{"type":"system","subtype":"init"}'
          echo '{"type":"assistant","error":"authentication_failed"}'
          echo '{"type":"result","subtype":"success","is_error":true,"api_error_status":null,"stop_reason":"stop_sequence","result":"Failed to authenticate: OAuth session expired and could not be refreshed"}'
          exit 1
        fi
        if [ -f "$D/limit" ]; then
          echo '{"type":"assistant","error":"rate_limit"}'
          echo '{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"You have hit your limit"}'
          exit 1
        fi
        echo '{"type":"result","subtype":"success","is_error":false,"result":"整形後の文。","stop_reason":"end_turn"}'
        """
        let codexScript = "#!/bin/bash\nif [ \"$1\" = login ]; then echo 'Not logged in' >&2; exit 1; fi\nexit 1\n"
        try? claudeScript.write(to: claude, atomically: true, encoding: .utf8)
        try? codexScript.write(to: codex, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claude.path)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
        func calls() -> Int { ((try? String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").count }

        let savedDelays = PolishRecovery.retryDelays
        let savedCLI = Polisher.testCLIPath, savedCodex = CodexCLI.testPath, savedRoute = AIRoute.testOverride
        let savedClaudeKey = AnthropicAPI.testHidesKey, savedOpenAIKey = OpenAIAPI.testHidesKey
        PolishRecovery.retryDelays = [0, 0]
        Polisher.testCLIPath = claude.path; CodexCLI.testPath = codex.path; AIRoute.testOverride = .claude
        AnthropicAPI.testHidesKey = true; OpenAIAPI.testHidesKey = true
        defer {
            PolishRecovery.retryDelays = savedDelays
            Polisher.testCLIPath = savedCLI; CodexCLI.testPath = savedCodex; AIRoute.testOverride = savedRoute
            AnthropicAPI.testHidesKey = savedClaudeKey; OpenAIAPI.testHidesKey = savedOpenAIKey
            for provider in AIProvider.allCases { Polisher.resetAuthentication(provider) }
            try? fm.removeItem(at: dir)
        }
        let polisher = Polisher(model: "test-model", effort: "low", route: AIRoute(provider: .claude))
        let polish = { try polisher.polish("試験の文です。", timeout: 5) }
        func reset() {
            for name in ["bad", "calls", "loggedout", "expired", "limit"] { flag(name, nil) }
            Polisher.resetAuthentication(.claude)
        }

        // 1. 応答不正 → 再試行で回復
        reset(); flag("bad", "1")
        var statuses: [String] = []
        let recovered = try? PolishRecovery.run(status: { statuses.append($0) }, operation: polish)
        check("応答不正は再試行で回復する", recovered == "整形後の文。" && calls() == 2)
        check("再試行中は進捗に再接続中と出す", statuses.first?.hasPrefix("AIに再接続中") == true)

        final class Calls { let lock = NSLock(); var bySentence: [String: Int] = [:]
            func hit(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; bySentence[key, default: 0] += 1; return bySentence[key]! } }
        let perSentence = Calls()
        let early = EarlyPolisher { text, _, _ in
            if perSentence.hit(text) == 1 && text.hasPrefix("二文目") { throw Polisher.PolishError.badResponse }
            return text
        }
        let text = "一文目はここで終わる確認の文章です。二文目はここで一度だけ失敗する確認の文章です。"
        let earlyOutput = try? early.finish(text) { _, _ in }
        early.cancel()
        check("失敗した文だけを再試行する", earlyOutput?.contains("二文目") == true && perSentence.bySentence.values.reduce(0, +) == 3)

        // 2. 再試行も失敗 → やり直しの操作で回復
        reset(); flag("bad", "99")
        let job = PolishJob(text: "試験の文です。", model: "test-model", effort: "low", context: nil, client: nil, aliases: [:], instructions: "", jevSettings: JevSettings())
        let exhausted = error { try job.run() }
        check("再試行は3回で止まる", exhausted != nil && calls() == 3)
        if case .some(Polisher.PolishError.badResponse) = exhausted {} else { check("再試行の上限後は応答不正を返す", false) }
        flag("bad", "0"); Polisher.resetAuthentication(.claude)
        check("保持した文のやり直しで回復する", (try? job.run()) == "整形後の文。")

        // 3. 認証切れ → 再接続
        reset(); flag("loggedout", "1")
        check("未ログインは応答不正でなくログイン切れになる", isLogin(error(polish)))
        if case .needsLogin(let tool, let path, let arguments) = AIConnection.reconnect(provider: .claude) {
            check("再接続はログインの導線を返す", tool == "Claude Code" && path == claude.path && arguments == ["auth", "login"])
        } else { check("再接続はログインの導線を返す", false) }
        flag("loggedout", nil)
        if case .connected = AIConnection.reconnect(provider: .claude) { check("ログイン後の再接続は実際の応答まで確かめて接続済み", calls() >= 1) }
        else { check("ログイン後の再接続は実際の応答まで確かめて接続済み", false) }
        check("再接続のあとは補正が通る", (try? polish()) == "整形後の文。")

        reset(); flag("expired", "1")
        check("認証は通るのに本番でログイン切れならログイン切れと分かる", isLogin(error(polish)))
        var loginAttempts = 0
        _ = try? PolishRecovery.run { loginAttempts += 1; return try polish() }
        check("ログイン切れは取り直して1回だけ再試行", loginAttempts == 2)
        if case .needsLogin = AIConnection.reconnect(provider: .claude) { check("本番のログイン切れも再接続で検出", true) }
        else { check("本番のログイン切れも再接続で検出", false) }

        // 再試行しないもの
        reset()
        var cancelledCalls = 0
        _ = try? PolishRecovery.run { cancelledCalls += 1; throw Polisher.PolishError.cancelled }
        check("キャンセルは再試行しない", cancelledCalls == 1)
        reset(); flag("limit", "1")
        var limitAttempts = 0
        let limitError = error { try PolishRecovery.run { limitAttempts += 1; return try polish() } }
        if case .some(Polisher.PolishError.usageLimit) = limitError { check("利用上限は再試行しない", limitAttempts == 1) }
        else { check("利用上限は再試行しない", false) }
        var refreshes = 0
        var transientCalls = 0
        _ = try? PolishRecovery.run(refresh: { refreshes += 1 }) {
            transientCalls += 1
            if transientCalls == 1 { throw URLError(.networkConnectionLost) }
            return "ok"
        }
        check("接続切れは認証を取り直して再試行", transientCalls == 2 && refreshes == 1)
        var timeouts = 0
        _ = try? PolishRecovery.run { timeouts += 1; throw Polisher.PolishError.timedOut }
        check("時間切れの再試行は1回まで", timeouts == 2)
        check("APIキーの拒否は再試行しない", PolishRecovery.kind(of: AnthropicAPI.Failure.http(401, "x")) == .stop && PolishRecovery.kind(of: OpenAIAPI.Failure.http(500, "x")) == .transient)

        // 接続先ごとの案内
        if case .needsLogin(let tool, _, let arguments) = AIConnection.reconnect(provider: .codexCLI) { check("Codex の未ログインは codex login へ案内", tool == "Codex" && arguments == ["login"]) }
        else { check("Codex の未ログインは codex login へ案内", false) }
        if case .needsKey(.openAIAPI) = AIConnection.reconnect(provider: .openAIAPI) { check("OpenAI のキー無しはキー設定へ案内", true) }
        else { check("OpenAI のキー無しはキー設定へ案内", false) }
        if case .needsKey(.claude) = AIConnection.outcome(for: AnthropicAPI.Failure.http(401, "x"), provider: .claude) { check("Claude のキー無効はキー設定へ案内", true) }
        else { check("Claude のキー無効はキー設定へ案内", false) }

        let script = try? AIConnection.writeLoginScript(tool: "Claude Code", executable: "/tmp/it's/claude", arguments: ["auth", "login"], folder: dir)
        let body = script.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        check("ログイン用コマンドは引数を安全に囲む", body.contains(#"'/tmp/it'\''s/claude' 'auth' 'login'"#))
        check("ログイン用コマンドは本人だけ実行できる", script.flatMap { try? fm.attributesOfItem(atPath: $0.path)[.posixPermissions] as? Int } == 0o700)
        if let script { try? fm.removeItem(at: script) }

        check("失敗の文言は押すボタンを示す", PolishRecovery.failureMessage(Polisher.PolishError.maxLoginRequired, provider: .claude).contains("AIにログイン…")
              && PolishRecovery.failureMessage(Polisher.PolishError.badResponse, provider: .claude).contains("AI補正をやり直す"))

        let recovery = dir.appendingPathComponent("recovery", isDirectory: true)
        try? fm.createDirectory(at: recovery, withIntermediateDirectories: true)
        func wav(_ name: String, _ date: Date, size: Int = 40_000) {
            let url = recovery.appendingPathComponent(name)
            fm.createFile(atPath: url.path, contents: Data(count: size), attributes: [.modificationDate: date])
        }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        wav("rec-old.wav", base)
        wav("rec-new.wav", base.addingTimeInterval(60))
        wav("rec-tiny.wav", base.addingTimeInterval(120), size: 100)
        check("未解決の録音は最新を選び、切れ端は除く", UnresolvedRecording.latest(in: recovery, resolvedThrough: nil)?.url.lastPathComponent == "rec-new.wav")
        check("解決済みの時刻より前の録音は繰り上げて出さない", UnresolvedRecording.latest(in: recovery, resolvedThrough: base.addingTimeInterval(90)) == nil)
        check("解決済みの時刻より後の録音は出す", UnresolvedRecording.latest(in: recovery, resolvedThrough: base.addingTimeInterval(30))?.url.lastPathComponent == "rec-new.wav")
        let temporary = dir.appendingPathComponent("tmp-check", isDirectory: true)
        try? fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        let writing = temporary.appendingPathComponent("rec-writing.wav"), leftover = temporary.appendingPathComponent("rec-leftover.wav")
        fm.createFile(atPath: writing.path, contents: Data(count: 10))
        fm.createFile(atPath: leftover.path, contents: Data(count: 10), attributes: [.modificationDate: Date().addingTimeInterval(-3600)])
        Paths.removeStaleTemporaryFiles(in: temporary)
        check("起動時の掃除は書き込み中の録音を消さない", fm.fileExists(atPath: writing.path))
        check("起動時の掃除は古い残りを消す", !fm.fileExists(atPath: leftover.path))
        if !AppDelegate.runMenuLayoutTests() { passed = false }
        return passed
    }
}
