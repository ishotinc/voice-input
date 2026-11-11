import Foundation

/// AI 補正の失敗から立て直す。回数と待ち時間を絞って再試行し、それでも駄目なら呼び出し側へ失敗を返す。
enum PolishRecovery {
    enum Kind { case cancelled, login, transient, stop }

    /// 再試行の前に待つ秒数。要素の数が再試行の上限。
    nonisolated(unsafe) static var retryDelays: [TimeInterval] = [0.5, 1.5]

    static func kind(of error: Error) -> Kind {
        if let polish = error as? Polisher.PolishError {
            switch polish {
            case .cancelled: return .cancelled
            case .maxLoginRequired, .codexLoginRequired: return .login
            case .badResponse, .timedOut, .codexFailed: return .transient
            case .cliMissing, .openAIKeyMissing, .codexMissing, .codexAPIKeyLogin, .usageLimit: return .stop
            }
        }
        if let api = error as? AnthropicAPI.Failure {
            switch api {
            case .http(let code, _): return httpKind(code)
            case .truncated: return .transient
            case .invalidKey, .keychain, .refusal: return .stop
            }
        }
        if let api = error as? OpenAIAPI.Failure {
            switch api {
            case .http(let code, _): return httpKind(code)
            case .truncated, .failed: return .transient
            case .invalidKey, .keychain, .refusal: return .stop
            }
        }
        return .transient   // 接続切れ（URLError）、更新中のコマンドを起動できないときなど
    }

    private static func httpKind(_ code: Int) -> Kind {
        code == 401 || code == 403 ? .stop : .transient
    }

    /// ログイン切れと時間切れは、確かめ直して1回だけ試す。ほかの一時的な失敗は上限まで試す。
    private static func retryLimit(_ error: Error) -> Int {
        let isTimeout: Bool
        if case Polisher.PolishError.timedOut = error { isTimeout = true } else { isTimeout = false }
        switch kind(of: error) {
        case .login: return min(1, retryDelays.count)
        case .transient: return isTimeout ? min(1, retryDelays.count) : retryDelays.count
        case .cancelled, .stop: return 0
        }
    }

    /// operation を実行し、一時的な失敗なら認証を取り直して再試行する。
    /// after に最初の失敗を渡すと、その失敗を1回目として数えて再試行から始める。
    static func run(after firstError: Error? = nil, cancelled: (() -> Bool)? = nil, status: ((String) -> Void)? = nil,
                    refresh: () -> Void = { Polisher.resetAuthentication() },
                    operation: () throws -> String) throws -> String {
        var failure = firstError
        var attempts = firstError == nil ? 0 : 1
        while true {
            if let error = failure {
                let limit = retryLimit(error)
                guard attempts <= limit, limit > 0, cancelled?() != true else { throw error }
                Log.write("AI補正を再試行 \(attempts)/\(limit): \(error.localizedDescription)")
                status?("AIに再接続中（再試行 \(attempts)/\(limit)）")
                refresh()
                Thread.sleep(forTimeInterval: retryDelays[attempts - 1])
                guard cancelled?() != true else { throw Polisher.PolishError.cancelled }
            }
            do {
                let value = try operation()
                if attempts > 0 { Log.write("AI補正の再試行で回復 \(attempts)回目") }
                return value
            } catch {
                failure = error
                attempts += 1
            }
        }
    }

    /// 失敗の表示に出す短い文。何が起きて、次に何を押すかだけを書く。
    static func failureMessage(_ error: Error, provider: AIProvider) -> String {
        let lead = "AI補正に失敗しました。未補正の文はコピー済みです。"
        switch kind(of: error) {
        case .login:
            return lead + (provider == .codexCLI ? "Codex" : "Claude Code") + " のログインが切れています。文章は保存してあります。「AIにログイン…」を押してください。"
        case .transient:
            return lead + "一時的な不具合です（3回まで試しました）。「AI補正をやり直す」を押してください。"
        case .cancelled, .stop:
            return lead + error.localizedDescription
        }
    }
}

/// メニューの「前回の録音からやり直す」の対象を選ぶ。
enum UnresolvedRecording {
    /// 復旧フォルダの録音のうち、resolvedThrough より新しいものの最新を返す。1秒未満の切れ端は対象にしない。
    /// resolvedThrough は初回起動の時刻で、それより前の録音は出さない。後の録音の成功では進めない。
    /// handled は扱い終えた録音の名前（ファイルを残す設定のときと、やり直しても文字が取れないとき）。
    static func latest(in folder: URL, resolvedThrough: Date?, handled: Set<String> = []) -> (url: URL, date: Date)? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return nil }
        return files.compactMap { url -> (url: URL, date: Date)? in
            guard url.lastPathComponent.hasPrefix("rec-"), url.pathExtension == "wav",
                  let values = try? url.resourceValues(forKeys: Set(keys)), let date = values.contentModificationDate,
                  (values.fileSize ?? 0) >= 32_000 else { return nil }
            if let resolvedThrough, date <= resolvedThrough { return nil }
            if handled.contains(url.lastPathComponent) { return nil }
            return (url, date)
        }.max { $0.date < $1.date }
    }
}

/// 未補正文をもう一度補正するための材料。ディスクに残すのは PendingPolish の範囲だけ（画面の内容は残さない）。
struct PolishJob {
    let text: String
    let model: String
    let effort: String
    let context: ScreenContext?
    let client: ClientContext?
    let aliases: [String: String]
    let instructions: String
    let jevSettings: JevSettings

    func run(status: ((String) -> Void)? = nil, progress: @escaping (Int, Int) -> Void = { _, _ in }) throws -> String {
        try SentencePolisher.polish(text, polisher: Polisher(model: model, effort: effort), context: context, client: client,
                                    aliases: aliases, instructions: instructions, jevSettings: jevSettings, status: status, progress: progress)
    }
}

/// 「AIに再接続」の中身。認証を確かめ直し、短い文で実際に応答が返るかまで見る。
enum AIConnection {
    enum Outcome {
        case connected(String)
        case needsLogin(tool: String, executable: String, arguments: [String])
        case needsKey(AIProvider)
        case failed(String)
    }

    static func reconnect(provider: AIProvider, probe: ((AIProvider) throws -> Void)? = nil) -> Outcome {
        Polisher.resetAuthentication(provider)
        do {
            if let missing = Polisher.missingRequirement(provider) { throw missing }
            try Polisher.ensureSubscription(provider)
            try (probe ?? defaultProbe)(provider)
            Log.write("AIに再接続: 接続できた (\(provider.rawValue))")
            return .connected(provider.shortName)
        } catch {
            Log.write("AIに再接続: 失敗 (\(provider.rawValue)) \(error.localizedDescription)")
            return outcome(for: error, provider: provider)
        }
    }

    static func defaultProbe(_ provider: AIProvider) throws {
        let settings = Settings.load()
        var route = AIRoute(settings: settings)
        route.provider = provider
        _ = try Polisher(model: settings.polishModel, effort: settings.polishEffort, route: route)
            .polish("接続確認のテストです", timeout: 30)
    }

    static func outcome(for error: Error, provider: AIProvider) -> Outcome {
        if let polish = error as? Polisher.PolishError {
            switch polish {
            case .maxLoginRequired:
                if let path = Polisher.cliPath { return .needsLogin(tool: "Claude Code", executable: path, arguments: ["auth", "login"]) }
            case .codexLoginRequired, .codexAPIKeyLogin:
                if let path = CodexCLI.path { return .needsLogin(tool: "Codex", executable: path, arguments: ["login"]) }
            case .cliMissing: return .needsKey(.claude)
            case .openAIKeyMissing: return .needsKey(.openAIAPI)
            default: break
            }
        }
        if case AnthropicAPI.Failure.http(let code, _) = error, code == 401 || code == 403 { return .needsKey(.claude) }
        if case OpenAIAPI.Failure.http(let code, _) = error, code == 401 || code == 403 { return .needsKey(.openAIAPI) }
        return .failed(error.localizedDescription)
    }

    /// ターミナルで開くログイン用の .command を作る。Apple Events の許可が要らない開き方。
    static func writeLoginScript(tool: String, executable: String, arguments: [String], folder: URL = Paths.tmp) throws -> URL {
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let url = folder.appendingPathComponent("login-\(UUID().uuidString).command")
        let command = ([executable] + arguments).map(quoted).joined(separator: " ")
        let script = "#!/bin/zsh\nrm -f -- \"$0\"\n\(command)\necho\necho '\(tool) のログインが済むと、音声入力が自動で確かめます。このウィンドウは閉じてかまいません。'\n"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
