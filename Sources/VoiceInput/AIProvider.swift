import Foundation

/// AI の仕上げに使うもの。既定は Claude（今までどおり）。
enum AIProvider: String, Codable, CaseIterable {
    /// Anthropic の API キーがあればそれ、無ければ Claude Code（Max ログイン）。
    case claude
    /// 利用者の OpenAI API キー（Responses API）。
    case openAIAPI = "openai-api"
    /// Codex CLI（ChatGPT のプランでログイン）。
    case codexCLI = "codex-cli"

    var menuTitle: String {
        switch self {
        case .claude: return "Claude（APIキー／Claude Code Max）"
        case .openAIAPI: return "OpenAI（APIキー）"
        case .codexCLI: return "OpenAI（Codex CLI・ChatGPTログイン）"
        }
    }
    var shortName: String {
        switch self {
        case .claude: return AnthropicAPI.hasKey ? "Claude APIキー" : "Claude Code Max"
        case .openAIAPI: return "OpenAI APIキー"
        case .codexCLI: return "Codex CLI"
        }
    }
}

/// 呼び出しの時点の設定。Polisher と会議の問い合わせが同じ設定を見る。
struct AIRoute {
    var provider: AIProvider
    var openAIModel: String
    var openAIEffort: String

    /// 試験用（--ai-provider）。常駐アプリの設定ファイルを書き換えずに道を選ぶ。
    nonisolated(unsafe) static var testOverride: AIProvider?
    static func current() -> AIRoute {
        var route = AIRoute(settings: Settings.load())
        if let testOverride { route.provider = testOverride }
        return route
    }
    init(settings: Settings) {
        provider = settings.aiProvider
        openAIModel = settings.openAIModel
        openAIEffort = settings.openAIEffort
    }
    init(provider: AIProvider, openAIModel: String = "gpt-6.1-sol", openAIEffort: String = "low") {
        self.provider = provider; self.openAIModel = openAIModel; self.openAIEffort = openAIEffort
    }
}

/// 端末に入った Codex CLI（npm i -g @openai/codex）を、1回だけ非対話で呼ぶ道。
/// 確かめた書き方（codex-cli 0.162.1 の --help）:
///   codex exec [OPTIONS] [PROMPT] … PROMPT を省くか - を渡すと標準入力を指示として読む
///   --json（イベントを JSONL で標準出力へ）/ -m モデル / -s read-only / --ephemeral（セッションを保存しない）
///   --ignore-user-config（~/.codex/config.toml を読まない。認証は CODEX_HOME のまま）/ --ignore-rules / --skip-git-repo-check
///   codex login status … ChatGPT なら標準エラーに「Logged in using ChatGPT」、未ログインは「Not logged in」で終了コード 1
enum CodexCLI {
    static var path: String? {
        [NSHomeDirectory() + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// ChatGPT でのログインだけを通す。API キーでのログインは「Codex CLI（ChatGPT）」として扱わない。
    static func loginState(_ data: Data) -> Polisher.PolishError? {
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { $0.hasPrefix("Logged in using ChatGPT") }) { return nil }
        if lines.contains(where: { $0.hasPrefix("Logged in using") }) { return .codexAPIKeyLogin }
        return .codexLoginRequired
    }

    static func checkLogin() throws {
        guard let path else { throw Polisher.PolishError.codexMissing }
        let started = ProcessInfo.processInfo.systemUptime
        defer { Log.write(String(format: "Codexログイン確認 %.3f秒", ProcessInfo.processInfo.systemUptime - started)) }
        // 状態は標準エラーに出る。未ログインは終了コード 1 なので、出力で判定する。中身はログに書かない。
        let data = try Polisher.runCLI(path: path, arguments: ["login", "status"], timeout: 15, stage: "Codexログイン確認",
                                       keepStderr: true, acceptFailureExit: true)
        if let problem = loginState(data) { throw problem }
    }

    /// TOML の文字列として -c に渡す値。
    static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// 道具を一切使わせず、指示文だけで1回答えさせる引数。
    /// 指示文は model_instructions_file（Codex 既定の指示の代わりに使う）で渡し、作業フォルダは空の一時フォルダにする。
    static func execArguments(model: String, effort: String, instructionsFile: String, workdir: String) -> [String] {
        var args = ["exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                    "--sandbox", "read-only", "--cd", workdir, "--model", model, "--color", "never", "--json"]
        let overrides = [
            "approval_policy=\"never\"",
            "web_search=\"disabled\"",
            "features.shell_tool=false",
            "features.multi_agent=false",
            "features.apps=false",
            "features.plugins=false",
            "features.image_generation=false",
            "features.browser_use=false",
            "features.computer_use=false",
            "features.memories=false",
            "project_doc_max_bytes=0",
            "include_environment_context=false",
            "skills.max_context_tokens=1",
            "hide_agent_reasoning=true",
            "model_reasoning_effort=" + tomlString(effort),
            "model_instructions_file=" + tomlString(instructionsFile),
        ]
        for value in overrides { args += ["-c", value] }
        return args + ["-"]
    }

    static func complete(system: String, input: String, model: String, effort: String, timeout: TimeInterval,
                         stage: String, cancelled: (() -> Bool)? = nil) throws -> String {
        guard let path else { throw Polisher.PolishError.codexMissing }
        let fm = FileManager.default
        let workdir = fm.temporaryDirectory.appendingPathComponent("voice-input-codex-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: workdir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: workdir) }
        let instructions = workdir.appendingPathComponent("instructions.md")
        try Data(system.utf8).write(to: instructions, options: [.atomic])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: instructions.path)
        let data = try Polisher.runCLI(path: path, arguments: execArguments(model: model, effort: effort, instructionsFile: instructions.path, workdir: workdir.path),
                                       input: input, timeout: timeout, stage: "Codex " + stage, cancelled: cancelled, acceptFailureExit: true)
        return try parseEvents(data)
    }

    /// codex exec --json のイベント列から最後の agent_message を採る。
    /// 失敗（turn.failed / error）・道具の実行・途中で終わった列は貼り付けない。
    static func parseEvents(_ data: Data) throws -> String {
        let lines = data.split(separator: 10).filter { !$0.allSatisfy { $0 == 13 || $0 == 32 || $0 == 9 } }
        guard !lines.isEmpty else { throw Polisher.PolishError.badResponse }
        var message: String?
        var completed = 0
        var lastType = ""
        for line in lines {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = event["type"] as? String else { throw Polisher.PolishError.badResponse }
            lastType = type
            switch type {
            case "thread.started", "turn.started": continue
            case "turn.completed": completed += 1
            case "turn.failed":
                let error = event["error"] as? [String: Any]
                throw Polisher.PolishError.codexFailed(failureText(error?["message"] as? String))
            case "error":
                throw Polisher.PolishError.codexFailed(failureText(event["message"] as? String))
            case "item.started", "item.updated", "item.completed":
                guard let item = event["item"] as? [String: Any], let itemType = item["type"] as? String else { throw Polisher.PolishError.badResponse }
                switch itemType {
                case "agent_message":
                    if type == "item.completed" { message = item["text"] as? String }
                case "reasoning", "error": continue   // error 項目は警告（例: モデル情報が無い）。本文には使わない。
                default: throw Polisher.PolishError.badResponse   // 道具（コマンド・ファイル変更・検索など）を使った応答は使わない。
                }
            default: continue
            }
        }
        guard completed == 1, lastType == "turn.completed", let message else { throw Polisher.PolishError.badResponse }
        let trimmed = AIText.unwrapWholeCodeFence(message.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty, trimmed.count < 32000 else { throw Polisher.PolishError.badResponse }
        return trimmed
    }

    /// 失敗の文は API のエラー JSON を文字列で包んでいることがある。中の message だけを短く出す。
    static func failureText(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "詳細不明" }
        if let data = raw.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return String(OpenAIAPI.redactKeys(message).prefix(200))
        }
        return String(OpenAIAPI.redactKeys(raw).prefix(200))
    }
}
