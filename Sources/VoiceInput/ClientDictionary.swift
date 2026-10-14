import Foundation
import CryptoKit
import NaturalLanguage

/// Local extraction only. Readings are never guessed; source snippets remain auditable.
enum ClientDictionary {
    struct Entry: Codable, Equatable {
        let kind: String
        let name: String
        let source: String
        let company: String
    }
    struct Cache: Codable {
        let version: Int
        let fingerprint: String
        let entries: [Entry]
    }
    static let version = 4
    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func extract(_ text: String) -> [Entry] {
        var result: [Entry] = [], source = "", company = ""
        func add(_ kind: String, _ raw: String) {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"[ 　]*(?:様|さん|氏)$"#, with: "", options: .regularExpression)
            guard !name.isEmpty, name.count <= 160 else { return }
            if kind == "person" && ["息子", "娘", "過去利用者", "利用者", "担当者", "客", "皆"].contains(name) { return }
            let entry = Entry(kind: kind, name: name, source: source, company: company)
            if !result.contains(entry) { result.append(entry) }
        }
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("--- "), line.hasSuffix(" ---") {
                source = String(line.dropFirst(4).dropLast(4)); company = ""; continue
            }
            let cleaned = line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            let patterns: [(String, String)] = [
                ("company", #"^(?:[-*|]\s*)?(?:company|会社名|社名|企業名)\s*[:：|]\s*(.+?)\s*\|?$"#),
                ("person", #"^(?:[-*|]\s*)?(?:contact|担当者|氏名|代表者|代表取締役)\s*[:：|]\s*(.+?)\s*\|?$"#),
                ("address", #"^(?:[-*|]\s*)?(?:address|住所|所在地|本社所在地)\s*[:：|]\s*(.+?)\s*\|?$"#),
                ("term", #"^(?:[-*|]\s*)?(?:商品名|サービス名|ブランド名|略称|読み|ふりがな)\s*[:：|]\s*(.+?)\s*\|?$"#)
            ]
            for (kind, pattern) in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                   let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
                   let range = Range(match.range(at: 1), in: cleaned) {
                    let value = String(cleaned[range])
                    if kind == "company" { company = value }
                    add(kind, value)
                }
            }
            // Honorific-marked names complement Japanese NLTagger's limited name recognition.
            if let regex = try? NSRegularExpression(pattern: #"([\p{Han}]{1,6}(?:[ 　][\p{Han}]{1,6})?)(?:さん|様|氏)"#) {
                for match in regex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) {
                    if let range = Range(match.range(at: 1), in: cleaned) {
                        let name = String(cleaned[range])
                        if !["客", "客様", "皆", "担当者", "利用者"].contains(name) { add("person", name) }
                    }
                }
            }
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = cleaned
            tagger.enumerateTags(in: cleaned.startIndex..<cleaned.endIndex, unit: .word, scheme: .nameType,
                                 options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
                if tag == .personalName, String(cleaned[range]).range(of: #"\p{Han}"#, options: .regularExpression) != nil { add("person", String(cleaned[range])) }
                else if tag == .organizationName { add("company", String(cleaned[range])) }
                else if tag == .placeName { add("place", String(cleaned[range])) }
                return true
            }
        }
        return result
    }
    static func cached(folder: String) -> ClientContext? {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".voice-input/client-dictionaries").appendingPathComponent(digest(folder) + ".json")
        guard let data = try? Data(contentsOf: url), data.count <= 2000000,
              let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == version else { return nil }
        var entries: [Entry] = [], bytes = 2
        let encoder = JSONEncoder()
        for entry in cache.entries {
            let size = (try? encoder.encode(entry).count) ?? 0
            if bytes + size + 1 > 32000 { break }
            entries.append(entry); bytes += size + 1
        }
        guard !entries.isEmpty, let encoded = try? encoder.encode(entries) else { return nil }
        return ClientContext(referenceText: String(decoding: encoded, as: UTF8.self),
                             fileCount: Set(entries.map(\.source)).count, truncated: entries.count < cache.entries.count, unavailable: false)
    }

    static func prepare(folder: String, cacheDirectory: URL? = nil) -> ClientContext {
        let raw = ClientContext.load(folderPath: folder, maxFiles: 100, maxCharacters: 200000, maxBytes: 2000000, perFileBytes: 160000, timeBudget: 3)
        guard !raw.unavailable, raw.fileCount > 0 else { return raw }
        let fingerprint = digest(raw.referenceText)
        let directory = cacheDirectory ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".voice-input/client-dictionaries")
        let url = directory.appendingPathComponent(digest(folder) + ".json")
        let cache: Cache
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Cache.self, from: data),
           saved.version == version, saved.fingerprint == fingerprint {
            cache = saved
        } else {
            cache = Cache(version: version, fingerprint: fingerprint, entries: extract(raw.referenceText))
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                try encoder.encode(cache).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { Log.write("顧客辞書の保存に失敗（今回の変換にはメモリ上の辞書を使用）") }
        }
        guard !cache.entries.isEmpty else {
            return ClientContext(referenceText: "", fileCount: 0, truncated: raw.truncated, unavailable: true)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var selected: [Entry] = [], usedBytes = 2
        for entry in cache.entries {
            let size = (try? encoder.encode(entry).count) ?? 0
            if usedBytes + size + 1 > 32000 { break }
            selected.append(entry); usedBytes += size + 1
        }
        let data = (try? encoder.encode(selected)) ?? Data()
        Log.write("顧客辞書: MD \(raw.referenceText.count)文字 → JSON \(data.count)バイト / \(cache.entries.count)件")
        return ClientContext(referenceText: String(decoding: data, as: UTF8.self), fileCount: raw.fileCount,
                             truncated: raw.truncated || selected.count < cache.entries.count, unavailable: false)
    }
}

/// Each recording owns one snapshot; later folder selections cannot change its reference.
final class ReferencePreparation {
    private let group = DispatchGroup()
    private var context: ClientContext?
    init(folder: String, cachedOnly: Bool = false) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            if !folder.isEmpty { self.context = cachedOnly ? ClientDictionary.cached(folder: folder) : ClientDictionary.prepare(folder: folder) }
            self.group.leave()
        }
    }
    func wait() -> ClientContext? { group.wait(); return context }
}
