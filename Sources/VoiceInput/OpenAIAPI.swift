import Foundation
import Security

/// 利用者自身の OpenAI API キーで OpenAI のモデルを呼ぶ道。考え方は AnthropicAPI と同じ。
/// キーはキーチェーンにだけ置く（service は Anthropic と別名）。設定ファイル・ログには書かない。
enum OpenAIKeychain {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.ishot.voice-input.openai", kSecAttrAccount as String: "api-key"] }

    /// OpenAI の API キーは sk- で始まる（プロジェクトキーは sk-proj-）。Anthropic のキー（sk-ant-）の貼り間違いは弾く。
    static func isValidFormat(_ raw: String) -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.hasPrefix("sk-") && !key.hasPrefix("sk-ant-") && key.count >= 20
            && key.unicodeScalars.allSatisfy { $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) }
    }
    static func read() -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }
    static func store(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // 形式の確認はキーチェーンに触る前に行う（自己テストで不正なキーを書き込まないため）。
        guard isValidFormat(key) else { throw OpenAIAPI.Failure.invalidKey }
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let existing = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if existing == errSecSuccess { return }
        guard existing == errSecItemNotFound else { throw OpenAIAPI.Failure.keychain(existing) }
        var q = query; q.merge(attributes) { _, new in new }
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw OpenAIAPI.Failure.keychain(status) }
    }
    static func remove() { SecItemDelete(query as CFDictionary) }
}

/// OpenAI Responses API（POST https://api.openai.com/v1/responses）。
enum OpenAIAPI {
    enum Failure: LocalizedError {
        case invalidKey, keychain(OSStatus), http(Int, String), refusal, truncated, failed(String)
        var errorDescription: String? {
            switch self {
            case .invalidKey: return "OpenAI の API キーは sk- で始まる文字列です（Claude のキー sk-ant- はここには入れません）。"
            case .keychain(let status): return "キーチェーンに保存できませんでした（\(status)）。"
            case .http(let code, let message): return "OpenAI API がエラーを返しました（\(code)）: \(message)"
            case .refusal: return "OpenAI のモデルが応答を控えました。仕上げを中止しました。"
            case .truncated: return "OpenAI API の応答が途中で切れました。"
            case .failed(let message): return "OpenAI API が応答を作れませんでした: \(message)"
            }
        }
    }

    static var hasKey: Bool { OpenAIKeychain.read() != nil }
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    /// 送る本文。store=false で応答を OpenAI 側に保存させない。ツールは渡さない。
    static func requestBody(system: String, input: String, model: String, effort: String?, maxOutputTokens: Int) -> [String: Any] {
        var body: [String: Any] = [
            "model": model, "instructions": system, "input": input,
            "max_output_tokens": maxOutputTokens, "store": false,
        ]
        if let effort, !effort.isEmpty { body["reasoning"] = ["effort": effort] }
        return body
    }

    /// 1回の問い合わせ。返すのはテキスト部分だけ。音声は送らない。
    static func complete(system: String, input: String, model: String, effort: String?, maxOutputTokens: Int = 16000,
                         timeout: TimeInterval, stage: String, cancelled: (() -> Bool)? = nil, key overrideKey: String? = nil) throws -> String {
        guard let key = overrideKey ?? OpenAIKeychain.read() else { throw Polisher.PolishError.openAIKeyMissing }
        guard input.utf8.count <= 128_000 else { throw Polisher.PolishError.badResponse }
        let started = ProcessInfo.processInfo.systemUptime
        defer { Log.write(String(format: "OpenAI API %@ 完了まで %.3f秒", stage, ProcessInfo.processInfo.systemUptime - started)) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(system: system, input: input, model: model, effort: effort, maxOutputTokens: maxOutputTokens))
        request.timeoutInterval = timeout.isFinite ? max(1, timeout) : 600

        final class Box: @unchecked Sendable { var data: Data?; var response: URLResponse?; var error: Error? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data; box.response = response; box.error = error
            done.signal()
        }
        task.resume()
        let deadline = Polisher.waitDeadline(timeout: timeout)
        while done.wait(timeout: cancelled == nil ? deadline : min(deadline, .now() + 0.2)) == .timedOut {
            if cancelled?() == true { task.cancel(); throw Polisher.PolishError.cancelled }
            if DispatchTime.now() >= deadline { task.cancel(); throw Polisher.PolishError.timedOut }
        }
        if let error = box.error {
            if (error as? URLError)?.code == .timedOut { throw Polisher.PolishError.timedOut }
            throw error
        }
        guard let http = box.response as? HTTPURLResponse, let data = box.data else { throw Polisher.PolishError.badResponse }
        guard http.statusCode == 200 else { throw Failure.http(http.statusCode, errorMessage(data)) }
        return try parseText(data)
    }

    /// OpenAI のエラー文は伏せ字にしたキーの一部を含むことがあるので、sk- 以降は消してから出す。
    static func errorMessage(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any], let message = error["message"] as? String else { return "詳細不明" }
        return String(redactKeys(message).prefix(200))
    }

    static func redactKeys(_ text: String) -> String {
        text.replacingOccurrences(of: #"sk-[A-Za-z0-9_\-\*\.]+"#, with: "sk-…", options: .regularExpression)
    }

    /// status=completed の応答の output_text だけを採る。途中で切れた応答・拒否・失敗・ツール呼び出しは貼り付けない。
    static func parseText(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? [[String: Any]] else { throw Polisher.PolishError.badResponse }
        switch json["status"] as? String {
        case "completed": break
        case "incomplete":
            let reason = (json["incomplete_details"] as? [String: Any])?["reason"] as? String
            throw reason == "content_filter" ? Failure.refusal : Failure.truncated
        case "failed":
            let message = ((json["error"] as? [String: Any])?["message"] as? String).map(redactKeys) ?? "詳細不明"
            throw Failure.failed(String(message.prefix(200)))
        default: throw Polisher.PolishError.badResponse
        }
        var text = ""
        for item in output {
            switch item["type"] as? String {
            case "reasoning": continue
            case "message":
                guard item["status"] == nil || item["status"] as? String == "completed" else { throw Failure.truncated }
                for part in item["content"] as? [[String: Any]] ?? [] {
                    switch part["type"] as? String {
                    case "output_text": text += part["text"] as? String ?? ""
                    case "refusal": throw Failure.refusal
                    default: throw Polisher.PolishError.badResponse
                    }
                }
            default: throw Polisher.PolishError.badResponse   // ツールは渡していない。想定外の項目は使わない。
            }
        }
        let trimmed = AIText.unwrapWholeCodeFence(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty, trimmed.count < 32000 else { throw Polisher.PolishError.badResponse }
        return trimmed
    }
}

enum AIText {
    /// 返答の全体が1つのコードブロック（```〜```）で包まれているときだけ中身を取り出す。
    /// 文中のコードブロックや、包まれていない返答には手を出さない。
    static func unwrapWholeCodeFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.count > 6 else { return trimmed }
        var lines = trimmed.components(separatedBy: "\n")
        guard lines.count >= 3, lines.last?.trimmingCharacters(in: .whitespaces) == "```" else { return trimmed }
        lines.removeFirst(); lines.removeLast()
        guard !lines.contains(where: { $0.hasPrefix("```") }) else { return trimmed }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
