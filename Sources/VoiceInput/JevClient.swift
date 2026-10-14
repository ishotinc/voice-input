import Foundation
import Security
import Darwin

struct JevSettings: Codable {
    var dictation = false
    var meeting = false
    var shadow = true
    var sharingAccepted = false
    var monthlyUSD = 10.0
    var meetingUSD = 1.0
    // No automatic adoption until a held-out Japanese evaluation supplies thresholds.
    var generalThreshold: Double? = nil
    var properThreshold: Double? = nil
    var evaluationID: String? = nil
    var canSend: Bool { sharingAccepted && monthlyUSD > 0 && monthlyUSD <= 10 && meetingUSD > 0 && meetingUSD <= monthlyUSD }
}

enum JevKeychain {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.ishot.voice-input.jev", kSecAttrAccount as String: "typesafe"] }
    static func read() -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func store(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw JevClient.Failure.configuration }
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let existing = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if existing == errSecSuccess { return }
        guard existing == errSecItemNotFound else { throw JevClient.Failure.keychain(existing) }
        var q = query; q.merge(attributes) { _, new in new }
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw JevClient.Failure.keychain(status) }
    }
    static func remove() { SecItemDelete(query as CFDictionary) }
}

/// Reserve the full server request allowance BEFORE sending. Unknown outcomes remain charged
/// conservatively across crashes/restarts; they are never treated as free cancellations.
final class JevBudget {
    struct Row: Codable { let month: String; let session: String; var tokens: Int; var confirmed: Bool }
    static let shared = JevBudget(url: Paths.settings.deletingLastPathComponent().appendingPathComponent("jev-usage.json"))
    static let price = 0.042 / 1_000_000.0
    static let reservationTokens = 65_536
    private let lock = NSLock()
    private let url: URL
    init(url: URL) { self.url = url }
    private func ledgerLock() throws -> Int32 {
        let fd = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw JevClient.Failure.budget }
        guard flock(fd, LOCK_EX) == 0 else { Darwin.close(fd); throw JevClient.Failure.budget }
        return fd
    }
    private func month() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM"; f.timeZone = TimeZone(secondsFromGMT: 0); return f.string(from: Date()) }
    private func load() throws -> [String: Row] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: Row].self, from: Data(contentsOf: url))
    }
    private func save(_ rows: [String: Row]) throws {
        try JSONEncoder().encode(rows).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func reserve(session: String, meeting: Bool, settings: JevSettings) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let fd = try ledgerLock(); defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard settings.canSend else { throw JevClient.Failure.configuration }
        var rows = try load()
        let monthly = rows.values.filter { $0.month == month() }.reduce(0) { $0 + $1.tokens }
        let perSession = rows.values.filter { $0.session == session }.reduce(0) { $0 + $1.tokens }
        guard Double(monthly + Self.reservationTokens) * Self.price <= settings.monthlyUSD,
              !meeting || Double(perSession + Self.reservationTokens) * Self.price <= settings.meetingUSD else { throw JevClient.Failure.budget }
        let id = UUID().uuidString
        rows[id] = Row(month: month(), session: session, tokens: Self.reservationTokens, confirmed: false)
        try save(rows); return id
    }
    func settle(_ id: String, tokens: Int) throws {
        guard (0...Self.reservationTokens).contains(tokens) else { throw JevClient.Failure.response }
        lock.lock(); defer { lock.unlock() }
        let fd = try ledgerLock(); defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        var rows = try load(); guard rows[id] != nil else { throw JevClient.Failure.budget }
        rows[id]?.tokens = tokens; rows[id]?.confirmed = true; try save(rows)
    }
    func usage() -> (confirmed: Double, reserved: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let fd = try? ledgerLock() else { return nil }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard let rows = try? load() else { return nil }
        let current = rows.values.filter { $0.month == month() }
        return (Double(current.filter(\.confirmed).reduce(0) { $0 + $1.tokens }) * Self.price,
                Double(current.filter { !$0.confirmed }.reduce(0) { $0 + $1.tokens }) * Self.price)
    }
}

final class JevClient {
    static let model = "jev-1.13.0"
    enum Failure: LocalizedError {
        case configuration, keychain(OSStatus), budget, timeout, response, http(Int), cancelled
        var errorDescription: String? {
            switch self {
            case .configuration: return "Jevのキー・送信同意・費用上限を設定してください。"
            case .keychain: return "JevのキーをKeychainに保存できませんでした。"
            case .budget: return "Jevの費用上限に達したか、使用量を確認できません。既存校正を使います。"
            case .timeout: return "Jevが時間内に応答しませんでした。"
            case .response: return "Jevの応答を検証できませんでした。"
            case .http(let code): return "JevのHTTPエラー \(code)"
            case .cancelled: return "Jev判定を取り消しました。"
            }
        }
    }
    struct Answer: Decodable {
        let type: String
        let choice: String
        let confidence: Double
        let probabilities: [String: Double]
    }
    struct Reply: Decodable {
        struct Usage: Decodable { let input_tokens: Int }
        let model: String
        let answers: [String: Answer]
        let usage: Usage
    }
    typealias Transport = (URLRequest, @escaping () -> Bool) throws -> (Data, Int)
    private static let slots = DispatchSemaphore(value: 2)
    private let transport: Transport
    private let budget: JevBudget
    private let key: () -> String?
    init(budget: JevBudget = .shared, key: @escaping () -> String? = JevKeychain.read,
         transport: @escaping Transport = JevClient.send) { self.budget = budget; self.key = key; self.transport = transport }
    static func send(_ request: URLRequest, cancelled: @escaping () -> Bool) throws -> (Data, Int) {
        final class Box { let lock = NSLock(); var result: Result<(Data, Int), Error>? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = request.timeoutInterval
        config.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request) { data, response, error in
            box.lock.lock(); defer { box.lock.unlock(); done.signal() }
            if let error { box.result = .failure(error) }
            else if let data, data.count < 1_000_000, let http = response as? HTTPURLResponse { box.result = .success((data, http.statusCode)) }
            else { box.result = .failure(Failure.response) }
        }
        task.resume()
        let deadline = Date().addingTimeInterval(request.timeoutInterval)
        while done.wait(timeout: .now() + 0.05) != .success {
            if cancelled() { task.cancel(); throw Failure.cancelled }
            if Date() >= deadline { task.cancel(); throw Failure.timeout }
        }
        box.lock.lock(); defer { box.lock.unlock() }
        return try box.result!.get()
    }
    func choose(state: [String: Any], questions: [String: [String: Any]], session: String,
                meeting: Bool, settings: JevSettings, cancelled: @escaping () -> Bool) throws -> Reply {
        guard settings.canSend, let secret = key(), !secret.isEmpty, !questions.isEmpty else { throw Failure.configuration }
        let body = try JSONSerialization.data(withJSONObject: ["model": Self.model, "state": state, "questions": questions], options: [.sortedKeys])
        // UTF-8 bytes are a conservative text-token ceiling. Leave ample envelope overhead;
        // the complete request also fits the stricter 32k state+longest-question limit.
        guard body.count + 2048 <= 30_000 else { throw Failure.configuration }
        let deadline = Date().addingTimeInterval(meeting ? 5 : 2)
        while Self.slots.wait(timeout: .now() + 0.05) != .success {
            if cancelled() { throw Failure.cancelled }; if Date() >= deadline { throw Failure.timeout }
        }
        defer { Self.slots.signal() }
        if cancelled() { throw Failure.cancelled }
        let id = try budget.reserve(session: session, meeting: meeting, settings: settings)
        var request = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        request.httpMethod = "POST"; request.httpBody = body
        request.timeoutInterval = max(0.1, deadline.timeIntervalSinceNow)
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, status) = try transport(request, cancelled)
        guard status == 200 else { throw Failure.http(status) }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.model == Self.model, Set(reply.answers.keys) == Set(questions.keys) else { throw Failure.response }
        for (id, answer) in reply.answers {
            guard let criteria = questions[id]?["criteria"] as? [String: String],
                  answer.type == "choice", criteria[answer.choice] != nil,
                  answer.confidence.isFinite, (0...1).contains(answer.confidence),
                  Set(answer.probabilities.keys) == Set(criteria.keys),
                  answer.probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  abs(answer.probabilities.values.reduce(0, +) - 1) < 0.025 else { throw Failure.response }
        }
        try budget.settle(id, tokens: reply.usage.input_tokens)
        Log.write("Jev model=\(reply.model) input_tokens=\(reply.usage.input_tokens) questions=\(questions.count)")
        return reply
    }
}
