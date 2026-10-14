import Foundation
import Security

/// 利用者自身の Anthropic API キーで Claude を呼ぶ道。
/// キーがキーチェーンにあればこちらを使い、無ければ従来どおり Claude Code（Max ログイン）を使う。
enum AnthropicKeychain {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.ishot.voice-input.anthropic", kSecAttrAccount as String: "api-key"] }
    static func read() -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }
    static func store(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-ant-") else { throw AnthropicAPI.Failure.invalidKey }
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let existing = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if existing == errSecSuccess { return }
        guard existing == errSecItemNotFound else { throw AnthropicAPI.Failure.keychain(existing) }
        var q = query; q.merge(attributes) { _, new in new }
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw AnthropicAPI.Failure.keychain(status) }
    }
    static func remove() { SecItemDelete(query as CFDictionary) }
}

enum AnthropicAPI {
    enum Failure: LocalizedError {
        case invalidKey, keychain(OSStatus), http(Int, String), refusal, truncated
        var errorDescription: String? {
            switch self {
            case .invalidKey: return "Anthropic の API キーは sk-ant- で始まる文字列です。"
            case .keychain(let status): return "キーチェーンに保存できませんでした（\(status)）。"
            case .http(let code, let message): return "Claude API がエラーを返しました（\(code)）: \(message)"
            case .refusal: return "Claude が応答を控えました。仕上げを中止しました。"
            case .truncated: return "Claude API の応答が途中で切れました。"
            }
        }
    }

    static var hasKey: Bool { AnthropicKeychain.read() != nil }

    /// 1回の問い合わせ。返すのはテキスト部分だけ。音声は送らない（送るのは文字にした内容と、呼び出し側が渡した参考情報のみ）。
    static func complete(system: String, input: String, model: String, effort: String?, maxTokens: Int = 16000,
                         timeout: TimeInterval, stage: String, cancelled: (() -> Bool)? = nil, key overrideKey: String? = nil) throws -> String {
        guard let key = overrideKey ?? AnthropicKeychain.read() else { throw Polisher.PolishError.cliMissing }
        guard input.utf8.count <= 128_000 else { throw Polisher.PolishError.badResponse }
        let started = ProcessInfo.processInfo.systemUptime
        defer { Log.write(String(format: "API %@ 完了まで %.3f秒", stage, ProcessInfo.processInfo.systemUptime - started)) }
        var body: [String: Any] = [
            "model": model, "max_tokens": maxTokens, "system": system,
            "messages": [["role": "user", "content": input]],
        ]
        if let effort { body["output_config"] = ["effort": effort] }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
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

    static func errorMessage(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any], let message = error["message"] as? String else { return "詳細不明" }
        return String(message.prefix(200))
    }

    /// end_turn で終わったテキストだけを採る。途中で切れた応答や拒否は貼り付けない。
    static func parseText(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { throw Polisher.PolishError.badResponse }
        switch json["stop_reason"] as? String {
        case "end_turn", "stop_sequence": break
        case "refusal": throw Failure.refusal
        case "max_tokens": throw Failure.truncated
        default: throw Polisher.PolishError.badResponse
        }
        let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 32000 else { throw Polisher.PolishError.badResponse }
        return trimmed
    }
}
