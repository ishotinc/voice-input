import Foundation

/// 用語辞書を自動で増やす仕組みの試験。`VoiceInput --learned-terms-test`（`--selftest` からも走る）。
/// 一時フォルダだけを使い、~/.voice-input には触らない。
enum LearnedTermsTests {
    static func run() -> Bool {
        var passed = true
        func check(_ name: String, _ good: Bool) { print((good ? "✅ " : "❌ ") + "自動の語: " + name); passed = passed && good }
        Log.testSkipsFile = true
        defer { Log.testSkipsFile = false }
        let now = Date()
        func daysAgo(_ n: Int) -> String { LearnedTerms.day(now.addingTimeInterval(-Double(n) * 86400)) }
        func obs(_ w: String, _ c: String) -> LearnedTerms.Observation { .init(wrong: w, correct: c) }
        let noGeneral: (String) -> Bool = { _ in false }
        let empty = TermDictionary()

        // 組の抽出
        let pairs = LearnedTerms.extract(before: "ユーテージのファネルを見て", after: "UTAGEのファネルを見て")
        check("置き換わった語の組だけを取り出す", pairs == [obs("ユーテージ", "UTAGE")])
        check("変わっていなければ組は無い", LearnedTerms.extract(before: "リード数を出して", after: "リード数を出して").isEmpty)
        check("句読点・空白の違いは組にしない", LearnedTerms.extract(before: "UTAGE のファネルを見て", after: "UTAGEのファネルを、見て。").isEmpty)
        let rewrite = LearnedTerms.extract(before: "明日の会議の資料をまとめておいてください",
                                           after: "週次ミーティング用のスライド一式を今日中に作成して共有してください")
        check("長い言い換えは組にしない", rewrite.allSatisfy { $0.wrong.count <= 20 } && !rewrite.contains(obs("明日の会議の資料をまとめておいて", "週次ミーティング用のスライド一式を今日中に作成して共有して")))

        // 登録してよい組か
        func reject(_ o: LearnedTerms.Observation, after: String = "", persons: [String] = [], general: ((String) -> Bool)? = nil) -> LearnedTerms.Rejection? {
            LearnedTerms.rejection(o, after: after, persons: persons, manual: empty, isGeneralWord: general ?? noGeneral)
        }
        check("用語らしい組は通す", reject(obs("ユーテージ", "UTAGE"), after: "UTAGEのファネル") == nil)
        check("数字を含む組は登録しない", reject(obs("3本", "三本")) == .number && reject(obs("じゅう件", "10件")) == .number)
        check("否定を含む組は登録しない", reject(obs("未送信", "送信済")) == .negation && reject(obs("出さない", "出す")) != nil)
        check("顧客辞書の人名は登録しない", reject(obs("高橋", "髙橋"), after: "髙橋に送って", persons: ["髙橋祐介"]) == .person)
        check("敬称つきの語は登録しない", reject(obs("スズキ", "鈴木"), after: "鈴木さんに送って") == .person)
        check("一般語の誤りは登録しない（固定置換の誤爆を防ぐ）", reject(obs("フリー", "freee"), general: LearnedTerms.isGeneralWord) == .general)
        check("ひらがなだけの誤りも一般語として扱う", LearnedTerms.isGeneralWord("うたげ") && !LearnedTerms.isGeneralWord("ユーテージ"))
        check("ひらがなの言い換えは拾わない", reject(obs("見て", "確認して")) == .shape)
        check("付け足し・省略は組にしない", reject(obs("LP", "LPページ")) == .overlap)
        var manual = TermDictionary(); manual.entries = [TermEntry(correct: "UTAGE", wrong: ["ウタゲ"])]
        check("手書きの辞書とぶつかる組は登録しない",
              LearnedTerms.rejection(obs("ウタゲ", "UTAGEX"), after: "", persons: [], manual: manual, isGeneralWord: noGeneral) == .manual
              && LearnedTerms.rejection(obs("UTAGE", "ウタゲ社"), after: "", persons: [], manual: manual, isGeneralWord: noGeneral) == .manual)

        // 画面の条件と回数
        var file = LearnedTermsFile()
        LearnedTerms.apply([obs("ノーション", "Notion")], to: &file, screenText: "Notion の管理画面", raw: "", now: now)
        check("画面に出ていた語は1回で登録", file.pairs.first?.registered == true && file.pairs.first?.seenOnScreen == true)
        var counted = LearnedTermsFile()
        for _ in 0..<2 { LearnedTerms.apply([obs("ジェブ", "Jev")], to: &counted, screenText: "", raw: "", now: now) }
        check("画面に無い語は2回では登録しない", counted.pairs.first?.registered == false && counted.pairs.first?.count == 2)
        LearnedTerms.apply([obs("ジェブ", "Jev")], to: &counted, screenText: "", raw: "", now: now)
        check("画面に無い語は3回で登録", counted.pairs.first?.registered == true)
        LearnedTerms.apply([obs("ジェブ", "Jeb")], to: &counted, screenText: "Jeb", raw: "", now: now)
        check("同じ誤りを別の語へ直す組は登録しない", counted.pairs.first { $0.correct == "Jeb" }?.registered == false)

        // 上限と期限切れ
        var big = LearnedTermsFile()
        big.pairs = (0..<250).map { LearnedPair(wrong: "ゴ\($0)", correct: "Go\($0)", count: 1, lastSeen: daysAgo($0 / 10), lastUsed: daysAgo($0 / 10), seenOnScreen: true, registered: true) }
        LearnedTerms.prune(&big, now: now)
        check("登録は200件まで（最近使った語を残す）", big.pairs.count == 200 && big.pairs.contains { $0.correct == "Go0" } && !big.pairs.contains { $0.correct == "Go249" })
        var old = LearnedTermsFile()
        old.pairs = [LearnedPair(wrong: "フルイ", correct: "Old", count: 5, lastSeen: daysAgo(61), lastUsed: daysAgo(61), seenOnScreen: true, registered: true),
                     LearnedPair(wrong: "マダ", correct: "Keep", count: 5, lastSeen: daysAgo(59), lastUsed: daysAgo(59), seenOnScreen: true, registered: true),
                     LearnedPair(wrong: "ツカウ", correct: "Used", count: 5, lastSeen: daysAgo(59), lastUsed: daysAgo(59), seenOnScreen: true, registered: true)]
        LearnedTerms.apply([], to: &old, screenText: "", raw: "ツカウの設定", now: now)
        check("60日使われなかった組は外す", !old.pairs.contains { $0.correct == "Old" } && old.pairs.contains { $0.correct == "Keep" })
        check("whisper の出力に当たった組は使われた日を更新", old.pairs.first { $0.correct == "Used" }?.lastUsed == LearnedTerms.day(now))

        // 保存・外す・辞書との合わせ方（一時フォルダ）
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("voice-learned-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = LearnedTermsStore(url: dir.appendingPathComponent("learned-terms.json"))
        let screen = ScreenContext(appName: "Test", windowTitle: "Notion", focusedText: "Notion の設定")
        let sentence = "ノーションの設定を明日までに見直して"
        store.record(before: sentence, after: "Notionの設定を明日までに見直して", raw: sentence, screen: screen, client: nil, manual: empty)
        let saved = (try? String(contentsOf: store.url, encoding: .utf8)) ?? ""
        let mode = (try? fm.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int) ?? 0
        check("保存は組だけで、文章は書かない", store.registered.map(\.correct) == ["Notion"] && !saved.contains("明日までに") && mode == 0o600)
        let manualURL = dir.appendingPathComponent("terms.json")
        try? JSONEncoder().encode(manual).write(to: manualURL)
        let manualBefore = (try? Data(contentsOf: manualURL)) ?? Data()
        let loaded = TermDictionary.loadForDictation(manual: manualURL, learned: store.load())
        check("読み込み時に手書きの辞書と合わせる（手書きは書き換えない）",
              loaded.merged.entries.contains { $0.correct == "Notion" && $0.wrong == ["ノーション"] } && loaded.manual.entries.count == 1
              && (try? Data(contentsOf: manualURL)) == manualBefore)
        let formatted = Formatter(terms: loaded.merged, forbiddenWords: [], spaceAroundLatin: false, trimTrailingPeriod: false).format("ノーションを開いて。").text
        check("登録した語は固定置換に使う", formatted == "Notionを開いて。")
        store.remove(wrong: "ノーション", correct: "Notion")
        store.record(before: sentence, after: "Notionの設定を明日までに見直して", raw: sentence, screen: screen, client: nil, manual: empty)
        check("外した組は登録し直さない", store.registered.isEmpty && store.load().dismissed.count == 1)

        // Whisper のヒントの順番
        let hint = HintPrompt.build(screen: ["画面語"], learned: ["直した語"], client: ["顧客語"], dictionary: ["辞書語", "画面語"])
        check("ヒントは画面→直した語→顧客→辞書の順・重複なし", hint == "以下は日本語の作業指示です。画面語、直した語、顧客語、辞書語。")
        let long = HintPrompt.build(screen: (0..<100).map { "語\($0)" }, learned: [], dictionary: (0..<100).map { "辞書\($0)" })
        check("ヒントは長さを抑える", long.count <= HintPrompt.lead.count + HintPrompt.limit + 1)
        var recent = LearnedTermsFile()
        recent.pairs = [LearnedPair(wrong: "ア", correct: "Old", count: 9, lastSeen: daysAgo(5), lastUsed: daysAgo(5), seenOnScreen: true, registered: true),
                        LearnedPair(wrong: "イ", correct: "New", count: 1, lastSeen: daysAgo(0), lastUsed: daysAgo(0), seenOnScreen: true, registered: true),
                        LearnedPair(wrong: "ウ", correct: "Cand", count: 2, lastSeen: daysAgo(0), lastUsed: daysAgo(0), seenOnScreen: false, registered: false)]
        check("直した語は最近使った順・登録済みだけ", LearnedTerms.promptWords(from: recent) == ["New", "Old"])
        return passed
    }
}
