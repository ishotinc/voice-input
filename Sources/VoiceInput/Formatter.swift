import Foundation

/// 整形の結果。警告は出すだけで、本文は書き換えない。
struct FormatResult {
    var text: String
    var styleWarnings: [String] = []
}

/// Whisper の出力を「そのまま指示として通る短い文」に直す。
/// 順番は voice-input-tool.md の 1→4 に揃えている。
struct Formatter {
    var terms: TermDictionary
    var forbiddenWords: [String]
    var dropSelfCorrections: Bool
    /// 英数字と日本語の間に半角スペースを入れるか（「UTAGE のファネル」）。
    var spaceAroundLatin: Bool
    /// 最後の「。」を落とすか。1行の指示は句点なしのほうが指示として読みやすい。
    var trimTrailingPeriod: Bool

    init(terms: TermDictionary, forbiddenWords: [String], dropSelfCorrections: Bool = true,
         spaceAroundLatin: Bool = true, trimTrailingPeriod: Bool = true) {
        self.terms = terms
        self.forbiddenWords = forbiddenWords
        self.dropSelfCorrections = dropSelfCorrections
        self.spaceAroundLatin = spaceAroundLatin
        self.trimTrailingPeriod = trimTrailingPeriod
    }

    func format(_ raw: String) -> FormatResult {
        var text = normalizeWhitespace(raw)
        guard !text.isEmpty else { return FormatResult(text: "") }
        text = applyTerms(to: text)
        text = removeSpokenNoise(text)
        text = fixPunctuation(text)
        text = insertMissingCommas(text)
        text = splitIntoBullets(text)
        if spaceAroundLatin { text = spaceLatin(text) }
        if trimTrailingPeriod { text = dropTrailingPeriod(text) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return FormatResult(text: text, styleWarnings: styleWarnings(in: text))
    }

    // MARK: - 0. 下ごしらえ

    func normalizeWhitespace(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n")
        t = t.replacingOccurrences(of: "\u{3000}", with: " ")
        // whisper は文の区切りごとに改行を出す。いったん1行に戻してから組み直す。
        t = t.replacingOccurrences(of: "\n", with: "")
        t = regexReplace(t, #"[ \t]+"#, " ")
        // 日本語の間に入った半角スペースは読点の代わりにならないので落とす
        t = regexReplace(t, #"(?<=[ぁ-んァ-ヶ一-龥、。]) (?=[ぁ-んァ-ヶ一-龥、。])"#, "")
        // whisper は句読点を半角で出すことがある。日本語の直後のものだけ全角に寄せる。
        // 「4.5」「index.html」を壊さないよう、前が日本語のときに限る。
        t = regexReplace(t, #"(?<=[ぁ-んァ-ヶ一-龥])\.(?=[ぁ-んァ-ヶ一-龥]|$)"#, "。")
        t = regexReplace(t, #"(?<=[ぁ-んァ-ヶ一-龥]),(?=[ぁ-んァ-ヶ一-龥])"#, "、")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 1. 用語の取り違えを直す

    func applyTerms(to input: String) -> String {
        var text = input
        // 長い誤変換から当てないと、短いほうが先に食ってしまう
        let pairs: [(wrong: String, correct: String, context: [String])] = terms.entries
            .flatMap { e in e.wrong.map { (wrong: $0, correct: e.correct, context: e.context) } }
            .sorted { $0.wrong.count > $1.wrong.count }

        for pair in pairs {
            guard !pair.wrong.isEmpty, pair.wrong != pair.correct else { continue }
            if !pair.context.isEmpty {
                let hit = pair.context.contains { text.localizedCaseInsensitiveContains($0) }
                if !hit { continue }
            }
            if isASCII(pair.wrong) {
                // free → freee のような取りこぼし・取りすぎを防ぐ
                let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: pair.wrong)
                    + "(?![A-Za-z0-9])"
                text = regexReplace(text, pattern, pair.correct, caseInsensitive: true)
            } else {
                text = text.replacingOccurrences(of: pair.wrong, with: pair.correct)
            }
        }
        return text
    }

    private func isASCII(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    // MARK: - 2. 話し言葉の余りを削る

    private static let fillers = ["えーと", "えっと", "ええと", "えー", "あのー", "あの",
                                 "そのー", "まあ", "まぁ", "なんか", "ま、"]

    func removeSpokenNoise(_ input: String) -> String {
        var text = input

        // フィラー: 文頭か読点の直後に出たものだけ落とす。文中の「あの人」は残す。
        for filler in Formatter.fillers {
            let f = NSRegularExpression.escapedPattern(for: filler)
            text = regexReplace(text, "(^|(?<=[、。]))\(f)、", "")
            text = regexReplace(text, "(^|(?<=[、。]))\(f)(?=[ぁ-んァ-ヶ一-龥])", "")
        }

        // 「えー」が単独のアルファベット＋区切りとして出てくることがある（whisper の癖）。
        // 1文字に限る。「LP、」のような意味のある頭出しを落とさないため。
        text = regexReplace(text, #"(^|(?<=[。]))[A-Za-z][、。,.]\s*"#, "")

        // 相づち: 単独で1文になっているものだけ落とす
        text = regexReplace(text, #"(^|(?<=[。]))(はい|うん|うんうん|ええ|そうそう)[、。]"#, "")

        // 言い直し: 「〜じゃなくて、〜」は後から言ったほうを残す。
        // 直前の言い直し対象が短いときだけ当てる（「main じゃなくて」のような指示語を消さないため）。
        if dropSelfCorrections {
            text = regexReplace(text, #"(^|[。])[^。]{1,25}?(?:じゃなくて|ではなくて|じゃなく|ではなく)、"#, "$1")
        }

        text = regexReplace(text, #"、{2,}"#, "、")
        text = regexReplace(text, #"^[、。\s]+"#, "")
        return text
    }

    // MARK: - 3. 句読点と改行

    func fixPunctuation(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }
        // 文末が「〜して」「〜ください」等で終わって句点がないときに補う
        let last = text.last!
        if !"。！？!?」）)".contains(last) {
            text += "。"
        }
        text = text.replacingOccurrences(of: "、。", with: "。")
        return text
    }

    /// whisper は読点を落とすことがある。
    /// 「〜て〜て〜て」と続く長い文にだけ、て形の切れ目へ読点を補う。
    /// 1か所しか当たらない文は触らない（「について」等を壊さないため）。
    func insertMissingCommas(_ input: String) -> String {
        splitSentences(input).map { sentence -> String in
            guard !sentence.contains("、"), sentence.count >= 20 else { return sentence }
            let pattern = #"(?<=[ぁ-んァ-ヶ一-龥])(?<!つい)(?<!とし)(?<!まし)([てで])(?=[ァ-ヶ一-龥])"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { return sentence }
            let range = NSRange(sentence.startIndex..<sentence.endIndex, in: sentence)
            guard re.numberOfMatches(in: sentence, range: range) >= 2 else { return sentence }
            return re.stringByReplacingMatches(in: sentence, range: range, withTemplate: "$1、")
        }.joined()
    }

    /// 「〜して、〜して、〜して」と続いたら箇条書きに割る。Claude Code には箇条書きのほうが通る。
    func splitIntoBullets(_ input: String) -> String {
        let sentences = splitSentences(input)
        var out: [String] = []
        for sentence in sentences {
            let parts = sentence
                .replacingOccurrences(of: "。", with: "")
                .components(separatedBy: "、")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let teCount = parts.dropLast().filter { $0.hasSuffix("て") || $0.hasSuffix("で") }.count
            if parts.count >= 3 && teCount >= 2 {
                out.append(contentsOf: parts.map { "- \($0)" })
            } else {
                out.append(sentence)
            }
        }
        return out.joined(separator: "\n")
    }

    /// 英数字と日本語がぶつかるところに半角スペースを入れる。
    /// 数字だけの塊（「3本」「5件」）は助数詞から離さない。英字を含む塊だけ離す。
    func spaceLatin(_ input: String) -> String {
        func isAlnum(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
        func isJoiner(_ c: Character) -> Bool { "-_./".contains(c) }
        func isJapanese(_ c: Character) -> Bool {
            guard let v = c.unicodeScalars.first?.value, c.unicodeScalars.count == 1 else { return false }
            return (0x3040...0x309F).contains(v)      // ひらがな
                || (0x30A0...0x30FF).contains(v)      // カタカナ（ー を含む）
                || (0x4E00...0x9FFF).contains(v)      // 漢字
                || v == 0x3005                        // 々
        }

        let chars = Array(input)
        var out: [Character] = []
        var i = 0
        while i < chars.count {
            guard isAlnum(chars[i]) else {
                out.append(chars[i]); i += 1; continue
            }
            var j = i
            while j < chars.count {
                if isAlnum(chars[j]) { j += 1 }
                else if isJoiner(chars[j]), j + 1 < chars.count, isAlnum(chars[j + 1]) { j += 2 }
                else { break }
            }
            let run = Array(chars[i..<j])
            let hasLetter = run.contains { $0.isASCII && $0.isLetter }
            if hasLetter, let prev = out.last, isJapanese(prev) { out.append(" ") }
            out.append(contentsOf: run)
            if hasLetter, j < chars.count, isJapanese(chars[j]) { out.append(" ") }
            i = j
        }
        return String(out)
    }

    /// 各行の末尾の句点を落とす。1行1指示なので句点は要らない。
    /// 「！」「？」は意味が変わるので残す。
    func dropTrailingPeriod(_ input: String) -> String {
        input.components(separatedBy: "\n").map { line -> String in
            var l = line
            while l.hasSuffix("。") { l.removeLast() }
            return l
        }.joined(separator: "\n")
    }

    func splitSentences(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in input {
            current.append(ch)
            if ch == "。" || ch == "！" || ch == "？" {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result.filter { !$0.isEmpty }
    }

    // MARK: - 4. 社内の文体ルール（警告だけ）

    func styleWarnings(in text: String) -> [String] {
        forbiddenWords.filter { text.contains($0) }
    }

    // MARK: - 正規表現の薄い包み

    private func regexReplace(_ s: String, _ pattern: String, _ template: String,
                              caseInsensitive: Bool = false) -> String {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else {
            Log.write("正規表現が壊れている: \(pattern)")
            return s
        }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
    }
}

/// whisper が無音・小さい音に対して出す決まり文句。
/// 動画の字幕で学習しているため、静かな部屋で録るとこれが出る（実測: peak=0.017 の部屋で
/// 「ご視聴ありがとうございました。」が出た）。指示として話す言葉ではないので、
/// 出力全体がこれと一致したときだけ捨てる。部分一致では消さない。
enum Hallucination {
    static let phrases: Set<String> = [
        "ご視聴ありがとうございました",
        "ご視聴ありがとうございました。",
        "ありがとうございました",
        "ありがとうございました。",
        "おやすみなさい",
        "チャンネル登録お願いします",
        "チャンネル登録よろしくお願いします",
        "最後までご視聴いただきありがとうございました",
        "字幕視聴者",
        "字幕",
        "Thank you.",
        "Thanks for watching!",
        "you",
        "You",
    ]

    /// 出力全体が決まり文句そのものか。
    static func isOnly(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return phrases.contains(t)
    }
}

/// 禁止語リストは .claude/hooks/style-forbidden-words.json から読む。辞書を二重に持たない。
enum StyleWords {
    static func load(from path: String) -> [String] {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let words = json["words"] as? [String: Any] else {
            Log.write("禁止語リストを読めなかった: \(url.path)")
            return []
        }
        return Array(words.keys).sorted()
    }
}
