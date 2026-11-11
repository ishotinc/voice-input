import Foundation

/// 連携切れの検知と未解決の文章を、偽の claude / codex と一時フォルダで確かめる。
/// キーチェーン・実物の CLI・~/.voice-input の recovery と tmp には触らない。
enum AILinkTests {
    static func run() -> Bool {
        var passed = true
        func check(_ name: String, _ good: Bool) { print((good ? "PASS: " : "FAIL: ") + name); passed = passed && good }
        Log.testSkipsFile = true
        defer { Log.testSkipsFile = false }

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("voice-link-" + UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func flag(_ name: String, _ value: String?) {
            let url = dir.appendingPathComponent(name)
            if let value { try? value.write(to: url, atomically: true, encoding: .utf8) } else { try? fm.removeItem(at: url) }
        }
        func install(_ name: String, _ body: String) -> URL {
            let url = dir.appendingPathComponent(name)
            try? body.write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        // 実測した claude 2.1.316・codex 0.162.1 の出力の形を返す偽コマンド。
        let claude = install("claude", """
        #!/bin/bash
        D='\(dir.path)'
        if [ "$2" = auth ]; then
          echo x >> "$D/auth-calls"
          if [ -f "$D/slow" ]; then sleep 20; fi
          if [ -f "$D/garbage" ]; then echo 'not json'; exit 1; fi
          if [ -f "$D/loggedout" ]; then echo '{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}'; exit 1; fi
          echo '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}'; exit 0
        fi
        cat >/dev/null
        echo x >> "$D/polish-calls"
        if [ -f "$D/expired" ]; then
          echo '{"type":"assistant","error":"authentication_failed"}'
          echo '{"type":"result","subtype":"success","is_error":true,"api_error_status":null,"result":"Failed to authenticate: OAuth session expired and could not be refreshed"}'
          exit 1
        fi
        if [ -f "$D/limit" ]; then
          echo '{"type":"assistant","error":"rate_limit"}'
          echo '{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"You have hit your limit"}'
          exit 1
        fi
        echo '{"type":"result","subtype":"success","is_error":false,"result":"整形後の文。","stop_reason":"end_turn"}'
        """)
        let codex = install("codex", """
        #!/bin/bash
        if [ "$1" = login ]; then
          if [ -f '\(dir.path)/codex-in' ]; then echo 'Logged in using ChatGPT' >&2; exit 0; fi
          echo 'Not logged in' >&2; exit 1
        fi
        exit 1
        """)
        func count(_ name: String) -> Int { ((try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "").split(separator: "\n").count }

        let savedCLI = Polisher.testCLIPath, savedCodex = CodexCLI.testPath, savedRoute = AIRoute.testOverride
        let savedClaudeKey = AnthropicAPI.testHidesKey, savedOpenAIKey = OpenAIAPI.testHidesKey
        Polisher.testCLIPath = claude.path; CodexCLI.testPath = codex.path; AIRoute.testOverride = .claude
        AnthropicAPI.testHidesKey = true; OpenAIAPI.testHidesKey = true
        defer {
            Polisher.testCLIPath = savedCLI; CodexCLI.testPath = savedCodex; AIRoute.testOverride = savedRoute
            AnthropicAPI.testHidesKey = savedClaudeKey; OpenAIAPI.testHidesKey = savedOpenAIKey
            for provider in AIProvider.allCases { Polisher.resetAuthentication(provider) }
            try? fm.removeItem(at: dir)
        }

        var provider: AIProvider? = .claude
        var now: TimeInterval = 1000
        var changes: [(AILinkStatus, AILinkStatus)] = []
        func makeMonitor() -> AILinkMonitor {
            changes = []
            let monitor = AILinkMonitor(activeProvider: { provider }, clock: { now }, inline: true)
            monitor.onChange = { changes.append(($0, $1)) }
            return monitor
        }
        func isLogin(_ status: AILinkStatus, tool: String) -> Bool {
            if case .login(let name, _, _) = status.fix { return name == tool }
            return false
        }

        // 切れる → 「!」の状態 → ログインで解消
        var monitor = makeMonitor()
        monitor.checkNow()
        check("ログイン中は接続済み", monitor.status == .connected)
        flag("loggedout", "1")
        now += AILinkMonitor.normalInterval
        check("5分たつと確認の番になる", monitor.isDue)
        monitor.tick()
        check("偽の CLI の未ログインで切れた状態になる", isLogin(monitor.status, tool: "Claude Code"))
        if case .login(_, let path, let arguments) = monitor.status.fix { check("ログインの導線は claude auth login", path == claude.path && arguments == ["auth", "login"]) }
        else { check("ログインの導線は claude auth login", false) }
        check("「!」のアイコンを作れる", AILinkIcon.image() != nil && AILinkIcon.image()?.isTemplate == false)
        now += 29
        check("切れているあいだも30秒までは待つ", !monitor.isDue)
        now += 1
        check("切れているあいだは30秒で確認する", monitor.isDue)
        flag("loggedout", nil)
        monitor.tick()
        check("ログインが済むと自動で接続済みに戻る", monitor.status == .connected)
        check("切れた→戻ったの変化を知らせる", changes.contains { $0.0 == .connected && $0.1.fix != nil } && changes.contains { $0.0.fix != nil && $0.1 == .connected })
        check("定期の確認は補正を呼ばない", count("polish-calls") == 0 && count("auth-calls") >= 3)

        // 実際の補正の失敗も同じ状態にする
        flag("expired", "1")
        let polisher = Polisher(model: "test-model", effort: "low", route: AIRoute(provider: .claude))
        func polishError() -> Error? { do { _ = try polisher.polish("試験の文です。", timeout: 5); return nil } catch { return error } }
        Polisher.resetAuthentication(.claude)
        monitor = makeMonitor()
        monitor.checkNow()
        monitor.reportPolish(polishError(), provider: .claude)
        check("本番のログイン切れでも切れた状態になる", isLogin(monitor.status, tool: "Claude Code"))
        let probesWhileExpired = count("polish-calls")
        check("軽い確認が通っても本番の失敗なら解除しない", monitor.tracker.needsRealResponseCheck && monitor.status.fix != nil)
        now += 10
        monitor.checkNow()
        check("確認の間隔を守って実際の応答は聞かない", count("polish-calls") == probesWhileExpired && monitor.status.fix != nil)
        flag("expired", nil)
        now += AILinkMonitor.probeInterval
        let beforeRecovery = count("polish-calls")
        monitor.checkNow()
        check("ログイン後は短い文の応答1回で解消する", monitor.status == .connected && count("polish-calls") == beforeRecovery + 1)
        monitor.checkNow()
        check("解消したら実際の応答は聞かない", count("polish-calls") == beforeRecovery + 1)

        // 軽い確認でも切れているなら、補正を呼ばずに解消できる
        monitor = makeMonitor()
        monitor.checkNow()
        monitor.reportPolish(Polisher.PolishError.maxLoginRequired, provider: .claude)
        flag("loggedout", "1"); now += 1; monitor.checkNow()
        check("軽い確認でも切れていれば応答の確認は不要", !monitor.tracker.needsRealResponseCheck)
        flag("loggedout", nil)
        let beforeLight = count("polish-calls")
        now += 30; monitor.checkNow()
        check("ログイン後は軽い確認だけで解消する", monitor.status == .connected && count("polish-calls") == beforeLight)

        // ログイン切れと混同しないもの
        monitor = makeMonitor()
        monitor.checkNow()
        monitor.reportPolish(Polisher.PolishError.usageLimit, provider: .claude)
        check("利用上限は「!」にしない", monitor.status.fix == nil)
        check("利用上限は状態の説明を出す", monitor.status.blockedMessage?.contains("利用上限") == true)
        monitor.checkNow()
        check("利用上限は軽い確認が通っても説明を残す", monitor.status.blockedMessage != nil)
        monitor.clearPolishBlock(); monitor.checkNow()
        check("次の録音で利用上限の説明を外す", monitor.status == .connected)
        monitor.reportPolish(URLError(.notConnectedToInternet), provider: .claude)
        check("通信の失敗では状態を変えない", monitor.status == .connected)
        monitor.reportPolish(Polisher.PolishError.timedOut, provider: .claude)
        check("時間切れでは状態を変えない", monitor.status == .connected)
        monitor.reportPolish(AnthropicAPI.Failure.http(429, "x"), provider: .claude)
        check("API の 429 では状態を変えない", monitor.status == .connected)
        monitor.reportPolish(AnthropicAPI.Failure.http(401, "x"), provider: .claude)
        check("API の 401 はキーの設定へ案内する", monitor.status.fix == .key(.claude))
        monitor.noteKeyChanged()
        check("キーを入れ直したら解消する", monitor.status == .connected)

        flag("garbage", "1"); now += 400
        monitor.tick()
        check("確認の出力が壊れていても切れた扱いにしない", monitor.status == .connected)
        flag("loggedout", "1"); flag("garbage", nil); now += 400; monitor.tick()
        flag("loggedout", nil); flag("garbage", "1"); now += 30; monitor.tick()
        check("切れている最中の一時的な失敗では解除しない", monitor.status.fix != nil)
        flag("garbage", nil)

        // 接続先ごとの確認
        provider = .codexCLI
        monitor = makeMonitor()
        monitor.checkNow()
        check("Codex の未ログインは codex login へ案内", isLogin(monitor.status, tool: "Codex"))
        flag("codex-in", "1"); now += 30; monitor.tick()
        check("Codex のログインが済むと解消する", monitor.status == .connected)
        provider = .openAIAPI
        monitor.checkNow()
        check("接続先を変えたら前の結果を使わない", monitor.status.fix == .key(.openAIAPI))
        provider = .claude
        monitor = makeMonitor()
        monitor.reportPolish(Polisher.PolishError.cliMissing, provider: .claude)
        check("Claude のキーも CLI も無ければキー設定へ案内", monitor.status.fix == .key(.claude))
        monitor.reportPolish(Polisher.PolishError.codexMissing, provider: .claude)
        check("コマンドが無いときはログインを促さず説明する", monitor.status.fix == nil && monitor.status.blockedMessage?.contains("Codex CLI が見つかりません") == true)
        provider = nil
        monitor.checkNow()
        check("高速入力モードでは確認しない", monitor.status == .unknown && monitor.tracker.provider == nil)
        provider = .claude

        // 未解決の文章の保存
        let folder = dir.appendingPathComponent("recovery", isDirectory: true)
        let store = PendingPolishStore(folder: folder)
        func item(_ text: String, at seconds: TimeInterval) -> PendingPolish {
            PendingPolish(id: UUID().uuidString, createdAt: Date(timeIntervalSince1970: seconds), text: text, styleWarnings: ["語"], targetBundleID: "com.example.app",
                          recordingName: "rec-\(Int(seconds)).wav", keepAudio: false, clientFolder: "")
        }
        let older = item("先に失敗した長い文章です。", at: 1_800_000_000), newer = item("後から失敗した文章です。", at: 1_800_000_100)
        check("未解決の文章を保存できる", (try? store.save(older)) != nil && (try? store.save(newer)) != nil)
        let saved = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        check("本人だけが読める 0600 で保存する", !saved.isEmpty && saved.allSatisfy { (try? fm.attributesOfItem(atPath: $0.path)[.posixPermissions] as? Int) == 0o600 })
        check("フォルダは 0700", (try? fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int) == 0o700)
        check("一時ファイルを残さない", saved.allSatisfy { !$0.lastPathComponent.hasSuffix(".tmp") })
        let reloaded = PendingPolishStore(folder: folder).loadAll()
        check("再起動相当で読み戻せる（新しいものから）", reloaded == [newer, older])
        let unrelated = folder.appendingPathComponent("2026-10-23-other.txt"), broken = folder.appendingPathComponent("unpolished-broken.json")
        try? "残す".write(to: unrelated, atomically: true, encoding: .utf8)
        try? "{".write(to: broken, atomically: true, encoding: .utf8)
        check("読めないファイルは飛ばす", store.loadAll() == [newer, older] && fm.fileExists(atPath: broken.path))
        check("id の形が違うものは消さない", { store.remove(id: "../2026-10-23-other"); return fm.fileExists(atPath: unrelated.path) }())
        let replaced = PendingPolish(id: newer.id, createdAt: newer.createdAt, text: "置き換え後です。", styleWarnings: [], targetBundleID: nil, recordingName: nil, keepAudio: false, clientFolder: "")
        check("同じ id は増やさず置き換える", (try? store.save(replaced)) != nil && store.loadAll().count == 2 && store.loadAll().first?.text == "置き換え後です。")
        store.remove(id: older.id)
        check("解決したものだけ外す", store.loadAll() == [replaced])
        store.remove(id: replaced.id)
        check("すべて解決すると空になる", store.loadAll().isEmpty)
        try? fm.removeItem(at: broken); try? fm.removeItem(at: unrelated)

        // 録音ファイル: 別の録音の解決に引きずられない
        func wav(_ name: String, _ date: Date) { fm.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data(count: 40_000), attributes: [.modificationDate: date]) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        wav("rec-first.wav", base); wav("rec-second.wav", base.addingTimeInterval(60))
        check("扱い終えた録音だけを除いて次を出す", UnresolvedRecording.latest(in: folder, resolvedThrough: nil, handled: ["rec-second.wav"])?.url.lastPathComponent == "rec-first.wav")
        try? fm.removeItem(at: folder.appendingPathComponent("rec-first.wav")); try? fm.removeItem(at: folder.appendingPathComponent("rec-second.wav"))

        Polisher.resetAuthentication(.claude)
        if !AppDelegate.runLinkMenuTests(folder: folder, cliPath: claude.path) { passed = false }
        return passed
    }
}
