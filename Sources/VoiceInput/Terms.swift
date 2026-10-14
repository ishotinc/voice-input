import Foundation

/// 用語辞書の1件。
/// - correct: 正しい表記
/// - wrong: よくある誤変換（長いものから当てる）
/// - context: 空でなければ、本文にこのどれかが出てきたときだけ置換する。
///   「フリー→freee」のように、普通の言葉と衝突する語を安全に扱うために使う。
struct TermEntry: Codable {
    var correct: String
    var wrong: [String]
    var context: [String] = []
    var note: String = ""

    // Swift の合成デコーダはプロパティの既定値を使わない。
    // 辞書を手で書き足すとき context / note を省けるように、ここで埋める。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        correct = try c.decode(String.self, forKey: .correct)
        wrong = try c.decodeIfPresent([String].self, forKey: .wrong) ?? []
        context = try c.decodeIfPresent([String].self, forKey: .context) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    init(correct: String, wrong: [String], context: [String] = [], note: String = "") {
        self.correct = correct
        self.wrong = wrong
        self.context = context
        self.note = note
    }
}

struct TermDictionary: Codable {
    var version: Int = 1
    var entries: [TermEntry] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        entries = try c.decodeIfPresent([TermEntry].self, forKey: .entries) ?? []
    }

    static func load(from url: URL = Paths.terms) -> TermDictionary {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(TermDictionary.self, from: data)
        } catch {
            Log.write("terms.json を読めなかった: \(url.path) — \(error)")
            return TermDictionary()
        }
    }

    /// whisper に渡す初期プロンプト。正しい表記を先に見せておくと誤変換が減る。
    /// 辞書が増えても長くしない。長すぎるプロンプトは効きが落ち、出力が揺れる。
    var initialPrompt: String {
        var words: [String] = []
        var length = 0
        for word in entries.map(\.correct) where length + word.count <= 180 {
            words.append(word)
            length += word.count + 1
        }
        return "以下は日本語の作業指示です。固有名詞: \(words.joined(separator: "、"))。"
    }
}
