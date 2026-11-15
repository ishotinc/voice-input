import Foundation
import NaturalLanguage

/// AI補正が直した語の組（誤→正）を数えて、条件を満たしたものを用語辞書に足す。
/// 保存するのは組と回数・最終日・画面に出ていたかだけ。文章そのものは保存しない。
/// 手書きの terms.json には書かず、~/.voice-input/learned-terms.json に分けて持つ。
struct LearnedPair: Codable, Equatable {
    var wrong: String
    var correct: String
    var count: Int
    /// 最後に直された日（yyyy-MM-dd）
    var lastSeen: String
    /// 最後に使われた日（直された日か、登録後に whisper の出力へ当たった日）。60日で外す基準。
    var lastUsed: String
    /// 録音開始時の画面に正しい表記が出ていたことがあるか
    var seenOnScreen: Bool
    var registered: Bool
}

struct LearnedTermsFile: Codable {
    struct Key: Codable, Hashable { var wrong: String; var correct: String }
    var version: Int = 1
    var pairs: [LearnedPair] = []
    /// 一覧から外した組。もう一度直されても登録し直さない。
    var dismissed: [Key] = []

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        pairs = try c.decodeIfPresent([LearnedPair].self, forKey: .pairs) ?? []
        dismissed = try c.decodeIfPresent([Key].self, forKey: .dismissed) ?? []
    }
}

enum LearnedTerms {
    static let registeredLimit = 200
    static let candidateLimit = 400
    static let dismissedLimit = 500
    static let expiryDays = 60
    static let countToRegister = 3

    /// 普段使うカタカナ語。SKK 辞書は「かな→漢字」なので、カタカナの一般語はここで拾う。
    /// これを wrong にした固定置換は誤爆する（例: 「フリー」→ freee）。
    static let commonKatakana: Set<String> = [
        "フリー", "メール", "ページ", "リスト", "データ", "サイト", "チーム", "ボード", "ファイル", "フォルダ", "フォルダー",
        "ツール", "システム", "サービス", "プラン", "ライン", "メモ", "タスク", "スライド", "レポート", "ニュース", "マップ",
        "カード", "ログ", "テスト", "セット", "ルール", "フォーム", "ボタン", "メニュー", "リンク", "コード", "キー", "モード",
        "タイプ", "グループ", "ユーザー", "ゲスト", "パス", "シート", "ノート", "スタート", "ストック", "クリック", "ミーティング",
        "セミナー", "イベント", "ゴール", "コスト", "スタッフ", "パート", "アプリ", "スマホ", "パソコン", "メッセージ", "コメント",
        "チェック", "スケジュール", "アカウント", "パスワード", "ログイン", "ダウンロード", "アップロード", "コピー", "ペースト",
    ]

    // MARK: - 組の取り出し（保存しない・純粋な計算）

    struct Observation: Equatable { let wrong: String; let correct: String }

    /// 「ルール整形後の Whisper 出力」と「AI補正後の文」を語の単位で比べ、置き換わった組だけを返す。
    /// 語の追加・削除・言い換えの長いものは返さない（誤認識の直しだけを拾う）。
    static func extract(before: String, after: String) -> [Observation] {
        let a = tokens(before), b = tokens(after)
        guard !a.isEmpty, !b.isEmpty, a.count <= 600, b.count <= 600 else { return [] }
        // 語の並びの最長共通部分で揃え、揃わなかった区間の「消えた語」と「入った語」を組にする。
        let n = a.count, m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i].text == b[j].text ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var i = 0, j = 0
        var result: [Observation] = []
        var removed: [Token] = [], added: [Token] = []
        func flush() {
            defer { removed = []; added = [] }
            guard !removed.isEmpty, !added.isEmpty, removed.count <= 3, added.count <= 3 else { return }
            let wrong = surface(before, removed), correct = surface(after, added)
            guard !wrong.isEmpty, !correct.isEmpty, wrong != correct else { return }
            let observation = Observation(wrong: wrong, correct: correct)
            if !result.contains(observation) { result.append(observation) }
        }
        while i < n || j < m {
            if i < n, j < m, a[i].text == b[j].text { flush(); i += 1; j += 1 }
            else if j < m, i == n || dp[i][j + 1] >= dp[i + 1][j] { added.append(b[j]); j += 1 }
            else { removed.append(a[i]); i += 1 }
        }
        flush()
        return result
    }

    private struct Token { let text: String; let range: Range<String.Index> }

    private static func tokens(_ text: String) -> [Token] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(.japanese)
        var out: [Token] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            out.append(Token(text: String(text[range]), range: range))
            return true
        }
        return out
    }

    /// 連続した語の元の表記。日本語にはさまった空白（整形で入る「UTAGE の」）は落とす。
    private static func surface(_ text: String, _ run: [Token]) -> String {
        guard let first = run.first, let last = run.last else { return "" }
        var s = String(text[first.range.lowerBound..<last.range.upperBound])
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if s.range(of: #"[ぁ-んァ-ヶ一-龯]"#, options: .regularExpression) != nil {
            s = s.replacingOccurrences(of: " ", with: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 登録してよい組か

    enum Rejection: String { case shape, number, negation, person, general, overlap, manual }

    /// 正しい表記は「用語らしい形」（英字・カタカナ・漢字の語。ひらがな・記号だけの言い換えは拾わない）。
    static func rejection(_ o: Observation, after: String, persons: [String], manual: TermDictionary,
                          isGeneralWord: (String) -> Bool = LearnedTerms.isGeneralWord) -> Rejection? {
        let termShape = #"^[A-Za-z0-9ァ-ヶー・一-龯々 ._\-]{2,30}$"#
        guard o.wrong.count >= 2, o.wrong.count <= 20,
              o.correct.range(of: termShape, options: .regularExpression) != nil,
              o.correct.range(of: #"[A-Za-zァ-ヶ一-龯]"#, options: .regularExpression) != nil,
              o.wrong.range(of: #"[A-Za-zぁ-んァ-ヶ一-龯]"#, options: .regularExpression) != nil else { return .shape }
        let digits = #"[0-9０-９〇零一二三四五六七八九十百千万億兆]"#
        if (o.wrong + o.correct).range(of: digits, options: .regularExpression) != nil { return .number }
        let negation = #"ない|なく|ません|ませ|ず|ぬ|じゃ|では|不|非|無|未|(?i:\bnot\b|\bno\b|\bnever\b|n't)"#
        if o.wrong.range(of: negation, options: .regularExpression) != nil
            || o.correct.range(of: negation, options: .regularExpression) != nil
            || !CorrectionCandidates.protected(o.wrong).isEmpty || !CorrectionCandidates.protected(o.correct).isEmpty { return .negation }
        if looksLikePerson(o.correct, in: after, persons: persons) || persons.contains(where: { o.wrong.contains($0) || $0.contains(o.wrong) }) { return .person }
        if o.correct.localizedCaseInsensitiveContains(o.wrong) || o.wrong.localizedCaseInsensitiveContains(o.correct) { return .overlap }
        let manualWrongs = Set(manual.entries.flatMap(\.wrong))
        let manualCorrects = Set(manual.entries.map(\.correct))
        if manualWrongs.contains(o.wrong) || manualCorrects.contains(o.wrong) || manualWrongs.contains(o.correct) { return .manual }
        if isGeneralWord(o.wrong) { return .general }
        return nil
    }

    /// 顧客辞書の人名・敬称つき・日本語の固有表現の人名は登録しない。
    static func looksLikePerson(_ word: String, in after: String, persons: [String]) -> Bool {
        if persons.contains(where: { !$0.isEmpty && (word.contains($0) || $0.contains(word)) }) { return true }
        let honorifics = ["さん", "様", "さま", "氏", "くん", "君", "ちゃん", "社長", "先生", "部長", "課長", "会長", "専務", "常務"]
        if honorifics.contains(where: { after.contains(word + $0) || after.contains(word + " " + $0) }) { return true }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = after
        var person = false
        tagger.enumerateTags(in: after.startIndex..<after.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName, String(after[range]).contains(word) || word.contains(String(after[range])) { person = true; return false }
            return true
        }
        return person
    }

    /// 普段使う一般語か。ひらがなだけの語・SKK 辞書にある語・よく使うカタカナ語。
    static func isGeneralWord(_ word: String) -> Bool {
        if word.range(of: #"^[ぁ-んー]+$"#, options: .regularExpression) != nil { return true }
        if commonKatakana.contains(word) { return true }
        let lexicon = CorrectionCandidates.lexicon
        return lexicon.surfaces[word] != nil || lexicon.readings[word] != nil
    }

    /// 顧客辞書（ClientContext.referenceText の JSON）から人名だけを取り出す。
    static func persons(from client: ClientContext?) -> [String] {
        guard let text = client?.referenceText, let data = text.data(using: .utf8),
              let entries = try? JSONDecoder().decode([ClientDictionary.Entry].self, from: data) else { return [] }
        return entries.filter { $0.kind == "person" }.map(\.name).filter { $0.count >= 2 }
    }

    // MARK: - 日付

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func daysBetween(_ older: String, _ newer: Date) -> Int {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let then = f.date(from: older), let now = f.date(from: day(newer)) else { return Int.max }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: then, to: now).day ?? Int.max
    }

    // MARK: - 記録（ファイルの読み書きと独立した計算）

    /// 1回の録音の結果を取り込む。screenText は録音開始時の画面（端末内のメモリだけ）。
    /// raw は整形前の Whisper 出力。登録済みの組が当たったら「使われた」とみなす（中身は保存しない）。
    static func apply(_ observations: [Observation], to file: inout LearnedTermsFile, screenText: String, raw: String, now: Date) {
        let today = day(now)
        let dismissed = Set(file.dismissed)
        for pair in file.pairs.indices where file.pairs[pair].registered && raw.contains(file.pairs[pair].wrong) {
            file.pairs[pair].lastUsed = today
        }
        for o in observations {
            guard !dismissed.contains(.init(wrong: o.wrong, correct: o.correct)) else { continue }
            let onScreen = !screenText.isEmpty && screenText.localizedCaseInsensitiveContains(o.correct)
            if let index = file.pairs.firstIndex(where: { $0.wrong == o.wrong && $0.correct == o.correct }) {
                file.pairs[index].count += 1
                file.pairs[index].lastSeen = today
                file.pairs[index].lastUsed = today
                file.pairs[index].seenOnScreen = file.pairs[index].seenOnScreen || onScreen
            } else {
                file.pairs.append(LearnedPair(wrong: o.wrong, correct: o.correct, count: 1, lastSeen: today, lastUsed: today,
                                              seenOnScreen: onScreen, registered: false))
            }
        }
        for index in file.pairs.indices where !file.pairs[index].registered {
            let p = file.pairs[index]
            // 同じ誤りを別の正解に直す組が登録済みなら足さない（固定置換がぶつかる）
            let conflict = file.pairs.contains { $0.registered && $0.wrong == p.wrong && $0.correct != p.correct }
            if !conflict && (p.seenOnScreen || p.count >= countToRegister) { file.pairs[index].registered = true }
        }
        prune(&file, now: now)
    }

    /// 60日使われなかった組を外し、登録済みは200件・候補は400件までに抑える（最近使われたものを残す）。
    static func prune(_ file: inout LearnedTermsFile, now: Date) {
        file.pairs.removeAll { daysBetween($0.lastUsed, now) > expiryDays }
        func newerFirst(_ x: LearnedPair, _ y: LearnedPair) -> Bool { x.lastUsed != y.lastUsed ? x.lastUsed > y.lastUsed : x.count > y.count }
        let registered = file.pairs.filter(\.registered).sorted(by: newerFirst).prefix(registeredLimit)
        let candidates = file.pairs.filter { !$0.registered }.sorted(by: newerFirst).prefix(candidateLimit)
        file.pairs = Array(registered) + Array(candidates)
        if file.dismissed.count > dismissedLimit { file.dismissed.removeFirst(file.dismissed.count - dismissedLimit) }
    }

    /// 登録済みの組を用語辞書の形にする。手書きの辞書の誤り表記とぶつかるものは使わない。
    static func entries(from file: LearnedTermsFile, manual: TermDictionary) -> [TermEntry] {
        let manualWrongs = Set(manual.entries.flatMap(\.wrong))
        var grouped: [String: [String]] = [:]
        var order: [String] = []
        for p in file.pairs where p.registered && !manualWrongs.contains(p.wrong) {
            if grouped[p.correct] == nil { order.append(p.correct) }
            grouped[p.correct, default: []].append(p.wrong)
        }
        return order.map { TermEntry(correct: $0, wrong: grouped[$0] ?? [], note: "自動で追加（learned-terms.json）") }
    }

    /// Whisper のヒントに載せる「最近よく直された語」。最近使われた順、同じ日なら回数の多い順。
    static func promptWords(from file: LearnedTermsFile, limit: Int = 12) -> [String] {
        var seen = Set<String>()
        return file.pairs.filter(\.registered)
            .sorted { $0.lastUsed != $1.lastUsed ? $0.lastUsed > $1.lastUsed : $0.count > $1.count }
            .map(\.correct).filter { seen.insert($0).inserted }.prefix(limit).map { $0 }
    }
}

/// learned-terms.json の読み書き。録音の処理（作業キュー）と設定ウィンドウ（メイン）から呼ばれるので鍵をかける。
final class LearnedTermsStore {
    static let shared = LearnedTermsStore(url: Paths.learnedTerms)
    let url: URL
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    func load() -> LearnedTermsFile {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    private func read() -> LearnedTermsFile {
        guard let data = try? Data(contentsOf: url) else { return LearnedTermsFile() }
        do { return try JSONDecoder().decode(LearnedTermsFile.self, from: data) }
        catch { Log.write("learned-terms.json を読めなかった（自動の語を使わずに続ける）"); return LearnedTermsFile() }
    }

    private func write(_ file: LearnedTermsFile) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(file).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { Log.write("learned-terms.json の保存に失敗") }
    }

    private func update(_ change: (inout LearnedTermsFile) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var file = read()
        change(&file)
        write(file)
    }

    /// 1回の録音を取り込む。ログに書くのは件数だけ（語も文章も書かない）。
    func record(before: String, after: String, raw: String, screen: ScreenContext?, client: ClientContext?, manual: TermDictionary, now: Date = Date()) {
        let persons = LearnedTerms.persons(from: client)
        let found = LearnedTerms.extract(before: before, after: after)
        let accepted = found.filter { LearnedTerms.rejection($0, after: after, persons: persons, manual: manual) == nil }
        let screenText = screen.map { $0.windowTitle + "\n" + $0.focusedText } ?? ""
        var registeredBefore = 0, registeredAfter = 0
        update { file in
            registeredBefore = file.pairs.filter(\.registered).count
            LearnedTerms.apply(accepted, to: &file, screenText: screenText, raw: raw, now: now)
            registeredAfter = file.pairs.filter(\.registered).count
        }
        if !found.isEmpty { Log.write("自動の語: 直し\(found.count)組・記録\(accepted.count)組・登録済み\(registeredBefore)→\(registeredAfter)件") }
    }

    /// 一覧から1件外す。同じ組はもう登録し直さない。
    func remove(wrong: String, correct: String) {
        update { file in
            file.pairs.removeAll { $0.wrong == wrong && $0.correct == correct }
            let key = LearnedTermsFile.Key(wrong: wrong, correct: correct)
            if !file.dismissed.contains(key) { file.dismissed.append(key) }
            LearnedTerms.prune(&file, now: Date())
        }
    }

    var registered: [LearnedPair] {
        load().pairs.filter(\.registered).sorted { $0.lastUsed != $1.lastUsed ? $0.lastUsed > $1.lastUsed : $0.count > $1.count }
    }
}

/// Whisper に渡すヒント。画面の語 → 最近よく直された語 → 顧客資料の語 → 既存辞書の順に載せ、長さを抑える。
/// ラベル語（「参考表記:」）は出力に漏れるので付けず、語を「、」で並べるだけにする。
enum HintPrompt {
    static let lead = "以下は日本語の作業指示です。"
    static let limit = 330

    static func build(screen: [String], learned: [String], client: [String] = [], dictionary: [String], limit: Int = HintPrompt.limit) -> String {
        var words: [String] = []
        var seen = Set<String>()
        var length = 0
        for word in screen + learned + client + dictionary {
            let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty, w.count <= 40, !w.contains("\n"), seen.insert(w).inserted else { continue }
            guard length + w.count + 1 <= limit else { continue }
            words.append(w)
            length += w.count + 1
        }
        return words.isEmpty ? lead : lead + words.joined(separator: "、") + "。"
    }

    /// 録音1回分のヒント。顧客資料の人名の読み（aliases）は顧客の語の先頭に置く。
    static func make(terms: TermDictionary, learned: LearnedTermsFile, screen: ScreenContext?, client: ClientContext?, aliases: [String: String]) -> String {
        let names = client.map { $0.validatedAliases(aliases).values.sorted() } ?? []
        return build(screen: screen?.vocabulary ?? [], learned: LearnedTerms.promptWords(from: learned),
                     client: names + (client?.vocabulary ?? []), dictionary: terms.entries.map(\.correct))
    }
}
