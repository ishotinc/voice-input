import Foundation
import NaturalLanguage

enum CorrectionCandidates {
    struct Choice: Codable, Equatable { let id: String; let text: String; let evidence: String; let proper: Bool }
    struct Span: Codable, Equatable {
        let id: String; let location: Int; let length: Int; let original: String; let choices: [Choice]
        var range: NSRange { NSRange(location: location, length: length) }
    }
    struct Lexicon {
        var readings: [String: [String]] = [:]
        var surfaces: [String: [String]] = [:]
        init(_ text: String) {
            for line in text.split(separator: "\n") where !line.hasPrefix(";") {
                let fields = line.split(separator: " ", maxSplits: 1)
                guard fields.count == 2, fields[0].range(of: "^[ぁ-ゖー]+$", options: .regularExpression) != nil else { continue }
                let words = fields[1].split(separator: "/").map { String($0.split(separator: ";", maxSplits: 1)[0]) }
                    .filter { (2...16).contains($0.count) && $0.range(of: "^[一-龯々ぁ-ゖァ-ヶー]+$", options: .regularExpression) != nil }
                let reading = String(fields[0]); readings[reading] = words
                for word in words { surfaces[word, default: []].append(reading) }
            }
        }
        func alternatives(_ word: String) -> [String] {
            var seen = Set<String>()
            let keys = surfaces[word] ?? (readings[word] == nil ? [] : [word])
            return keys.flatMap { readings[$0] ?? [] }.filter { seen.insert($0).inserted }
        }
    }
    static let lexicon: Lexicon = {
        let locations = [Bundle.main.resourceURL?.appendingPathComponent("SKK-JISYO.L"),
                         // 開発時（.build/release/VoiceInput から直接動かすとき）はリポジトリの Resources を見る。
                         // #filePath はビルドした場所のフルパスをアプリに残すので使わない。
                         Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/SKK-JISYO.L")].compactMap { $0 }
        for url in locations {
            if let text = try? String(contentsOf: url, encoding: .japaneseEUC) { return Lexicon(text) }
        }
        return Lexicon("")
    }()
    static func make(_ text: String, references: [ClientDictionary.Entry] = [], screen: [String] = [], lexicon: Lexicon = lexicon) -> [Span] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text; tokenizer.setLanguage(.japanese)
        var spans: [Span] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range]), position = NSRange(range, in: text)
            guard word.count >= 2, spans.count < 12 else { return true }
            let alternatives = lexicon.alternatives(word)
            var choices: [Choice] = []
            for alternative in alternatives where alternative != word {
                let evidence = references.first { $0.name == alternative }
                let onScreen = screen.contains(alternative)
                choices.append(Choice(id: "c\(choices.count)", text: alternative,
                    evidence: evidence.map { "資料: " + $0.source } ?? (onScreen ? "入力画面" : "SKK-JISYO.Lの同一読み"),
                    proper: evidence.map { ["person", "company", "address", "place"].contains($0.kind) } ?? false))
                if choices.count == 8 { break }
            }
            guard !choices.isEmpty else { return true }
            spans.append(Span(id: "s\(position.location)", location: position.location, length: position.length, original: word, choices: choices))
            return true
        }
        return spans
    }
    static func protected(_ text: String) -> [String] {
        let pattern = "[0-9０-９]+(?:[.,．][0-9０-９]+)?|[〇零一二三四五六七八九十百千万億兆]+|前年比|増加率|減少率|税込|税別|パーセント|[%％]|ない|なく|ません|未定|未決|禁止|不要|必要|ではなく|決定|希望|依頼|お願い"
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }
    }
    static func apply(_ selections: [String: String], spans: [Span], original: String) throws -> String {
        var result = original
        var previous = (original as NSString).length
        for span in spans.sorted(by: { $0.location > $1.location }) {
            guard let selected = selections[span.id], selected != "keep" else { continue }
            guard span.location >= 0, span.length > 0, span.location + span.length <= previous,
                  (original as NSString).substring(with: span.range) == span.original,
                  let choice = span.choices.first(where: { $0.id == selected }),
                  let range = Range(span.range, in: result) else { throw JevClient.Failure.response }
            result.replaceSubrange(range, with: choice.text); previous = span.location
        }
        guard protected(result) == protected(original) else { throw JevClient.Failure.response }
        return result
    }
}
