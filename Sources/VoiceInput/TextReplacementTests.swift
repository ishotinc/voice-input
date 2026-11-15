import Foundation

/// 一時フォルダだけで検証する。本物のユーザ辞書・キーチェーン・画面は使わない。
enum TextReplacementTests {
    static func run() -> Bool {
        typealias Sync = TextReplacementSync
        typealias Pair = Sync.Pair
        var passed = true
        func check(_ name: String, _ good: Bool) {
            print((good ? "✅ " : "❌ ") + "ユーザ辞書: " + name)
            passed = passed && good
        }
        check("英字の用語だけを選ぶ", Sync.isLatinTerm("Google Docs") && Sync.isLatinTerm("e-Tax")
              && !Sync.isLatinTerm("日本語") && !Sync.isLatinTerm("UTAGEの設定") && !Sync.isLatinTerm(""))
        check("読みは英数字だけ・小文字", Sync.shortcut(for: "Google Docs") == "googledocs"
              && Sync.shortcut(for: "e-Tax") == "etax" && Sync.shortcut(for: "日本語") == nil)

        var manual = TermDictionary()
        manual.entries = [TermEntry(correct: "Google Docs", wrong: []), TermEntry(correct: "e-Tax", wrong: []),
                          TermEntry(correct: "日本語", wrong: []), TermEntry(correct: "google docs", wrong: []),
                          TermEntry(correct: "ClientCo", wrong: [])]
        for (i, note) in ["住所", "人名", "顧客", "定型"].enumerated() {
            manual.entries.append(TermEntry(correct: "Private\(i)", wrong: [], note: "除外する\(note)です"))
        }
        func learned(_ phrase: String, registered: Bool) -> LearnedPair {
            LearnedPair(wrong: "テスト", correct: phrase, count: 3, lastSeen: "2026-11-15", lastUsed: "2026-11-15",
                        seenOnScreen: true, registered: registered)
        }
        var file = LearnedTermsFile()
        file.pairs = [learned("UTAGE", registered: true), learned("Pending", registered: false),
                      learned("E-tax", registered: true), learned("CLIENTCO", registered: true),
                      learned("日本語", registered: true)]
        let candidates = Sync.candidates(manual: manual, learned: file, excludedNames: ["clientco"])
        check("英字だけ・注記と顧客名は除外・自動の語は登録済みだけ・重複なし",
              candidates == [Pair(shortcut: "googledocs", phrase: "Google Docs"),
                             Pair(shortcut: "etax", phrase: "e-Tax"), Pair(shortcut: "utage", phrase: "UTAGE")])
        let existing = [Pair(shortcut: "GOOGLEDOCS", phrase: "Other"), Pair(shortcut: "other", phrase: "E-TAX")]
        check("同じ読みか語句があれば大小を問わず足さない",
              Sync.plan(candidates, existing: existing) == [Pair(shortcut: "utage", phrase: "UTAGE")])
        check("今回の候補同士でも読みと語句を重ねない",
              Sync.plan([Pair(shortcut: "etax", phrase: "e-Tax"), Pair(shortcut: "ETAX", phrase: "e Tax"),
                         Pair(shortcut: "docs", phrase: "E-TAX")], existing: []) == [Pair(shortcut: "etax", phrase: "e-Tax")])

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = Sync.State()
        check("初回は5分以上操作がなければ動く", Sync.shouldRun(now: now, state: state, idleSeconds: 300, busy: false, screenAvailable: true))
        check("録音・会議中は動かない", !Sync.shouldRun(now: now, state: state, idleSeconds: 1000, busy: true, screenAvailable: true))
        check("操作なしが5分未満なら動かない", !Sync.shouldRun(now: now, state: state, idleSeconds: 299, busy: false, screenAvailable: true))
        check("ロック中・消灯中は初回でも動かない", !Sync.shouldRun(now: now, state: state, idleSeconds: 1000, busy: false, screenAvailable: false))
        state.lastSuccess = now.addingTimeInterval(-Sync.interval + 1)
        check("成功から7日未満は動かない", !Sync.shouldRun(now: now, state: state, idleSeconds: 300, busy: false, screenAvailable: true))
        state.lastSuccess = now.addingTimeInterval(-Sync.interval)
        check("成功から7日で動く", Sync.shouldRun(now: now, state: state, idleSeconds: 300, busy: false, screenAvailable: true))
        state.lastFailure = now.addingTimeInterval(-Sync.retryAfterFailure + 1)
        check("失敗から6時間未満は動かない", !Sync.shouldRun(now: now, state: state, idleSeconds: 300, busy: false, screenAvailable: true))
        state.lastFailure = now.addingTimeInterval(-Sync.retryAfterFailure)
        check("失敗から6時間で再試行できる", Sync.shouldRun(now: now, state: state, idleSeconds: 300, busy: false, screenAvailable: true))
        check("ロック中・消灯中は週次・再試行の期限を過ぎても動かない",
              !Sync.shouldRun(now: now, state: state, idleSeconds: 1000, busy: false, screenAvailable: false))
        let os = "test macOS"
        func action(_ state: Sync.State, idle: TimeInterval = 300, busy: Bool = false,
                    screen: Bool = true, currentOS: String = "test macOS") -> Sync.Action {
            Sync.nextAction(now: now, state: state, currentOS: currentOS, idleSeconds: idle,
                            busy: busy, screenAvailable: screen)
        }
        var gate = Sync.State()
        check("印なしなら実機試験", action(gate) == .liveTest)
        gate.lastFailure = now
        check("古い本番失敗は実機試験を止めない", action(gate) == .liveTest)
        gate.lastFailure = nil
        for verified in [false, true] {
            gate.verifiedAt = verified ? now.addingTimeInterval(-60) : nil
            gate.verifiedOS = verified ? os : nil
            check("共通条件を満たさなければ動かない（印\(verified ? "あり" : "なし")）",
                  action(gate, idle: 299) == .none && action(gate, busy: true) == .none
                  && action(gate, screen: false) == .none)
        }
        check("印あり・未同期ならすぐ取り込む", action(gate) == .sync)
        gate.lastSuccess = now.addingTimeInterval(-120)
        check("印より前の同期なら7日待たない", action(gate) == .sync)
        gate.lastFailure = now.addingTimeInterval(-Sync.retryAfterFailure + 1)
        check("初回取り込みでも本番失敗から6時間待つ", action(gate) == .none)
        gate.lastFailure = now.addingTimeInterval(-Sync.retryAfterFailure)
        check("初回取り込みも本番失敗から6時間で再開", action(gate) == .sync)
        gate.lastFailure = nil
        gate.lastSuccess = now.addingTimeInterval(-30)
        check("印あり・同期から7日未満なら待つ", action(gate) == .none)
        gate.verifiedAt = now.addingTimeInterval(-Sync.interval - 60)
        gate.lastSuccess = now.addingTimeInterval(-Sync.interval + 1)
        check("本番同期の7日境界の直前は待つ", action(gate) == .none)
        gate.lastSuccess = now.addingTimeInterval(-Sync.interval)
        check("本番同期から7日で取り込む", action(gate) == .sync)
        check("OSが変わったら実機試験", action(gate, currentOS: "new macOS") == .liveTest)
        var invalidated = gate
        check("OS変更で両方の印を消す", invalidated.invalidateVerification(currentOS: "new macOS")
              && invalidated.verifiedAt == nil && invalidated.verifiedOS == nil)
        check("同じOSの印は残す", !gate.invalidateVerification(currentOS: os) && gate.isVerified(currentOS: os))
        gate.verifiedAt = nil
        check("OSだけあっても未試験扱い", action(gate) == .liveTest)
        gate.verifiedAt = now
        gate.verifiedOS = nil
        check("日時だけあっても未試験扱い", action(gate) == .liveTest)
        for (failures, wait) in [(1, 1800.0), (2, 7200.0), (3, 21600.0), (4, 21600.0)] {
            var retry = Sync.State()
            retry.testFailures = failures
            retry.lastTestFailure = now.addingTimeInterval(-wait + 1)
            check("実機試験失敗\(failures)回・待ち時間の直前は待つ", action(retry) == .none)
            retry.lastTestFailure = now.addingTimeInterval(-wait)
            check("実機試験失敗\(failures)回・期限で再試験", action(retry) == .liveTest)
        }

        let lastSynthetic = now.addingTimeInterval(-10)
        check("こちらの操作後に入力があれば中断", Sync.touched(secondsSinceInput: 2, now: now, lastSynthetic: lastSynthetic))
        check("新しい入力がなければ続ける", !Sync.touched(secondsSinceInput: 10, now: now, lastSynthetic: lastSynthetic)
              && !Sync.touched(secondsSinceInput: 20, now: now, lastSynthetic: lastSynthetic))

        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("voice-text-replacements-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let legacySettings = try JSONDecoder().decode(Settings.self, from: Data(#"{"learnTerms":false}"#.utf8))
            check("古い設定はユーザ辞書への取り込みを既定で有効にする",
                  legacySettings.syncTextReplacements && !legacySettings.learnTerms)
            var settings = Settings()
            settings.syncTextReplacements = false
            let settingsURL = folder.appendingPathComponent("settings.json")
            try JSONEncoder().encode(settings).write(to: settingsURL)
            let restoredSettings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsURL))
            check("ユーザ辞書への取り込みオフを保存・復元できる", !restoredSettings.syncTextReplacements)

            let cache = ClientDictionary.Cache(version: ClientDictionary.version, fingerprint: "test", entries:
                ["person", "company", "address", "place", "term"].map {
                    ClientDictionary.Entry(kind: $0, name: $0 + "Name", source: "test", company: $0 == "person" ? "ParentCo" : "")
                })
            try JSONEncoder().encode(cache).write(to: folder.appendingPathComponent("client.json"))
            check("顧客キャッシュの人名・社名・住所・地名を除外する",
                  Sync.excludedNames(folder: folder) == Set(["personName", "companyName", "addressName", "placeName", "ParentCo"]))
            let database = folder.appendingPathComponent("test.db")
            check("データベースがなければ空配列", try Sync.existing(database: database).isEmpty)
            check("読み取りでデータベースを作らない", !fm.fileExists(atPath: database.path))
            let broken = folder.appendingPathComponent("broken.db")
            try Data("not a database".utf8).write(to: broken)
            do {
                _ = try Sync.existing(database: broken)
                check("壊れたデータベースは失敗として知らせる", false)
            } catch Sync.UIError.database {
                check("壊れたデータベースは失敗として知らせる", true)
            }

            func sql(_ query: String) throws {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
                process.arguments = [database.path, query]
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw Sync.UIError.database }
            }
            try sql("CREATE TABLE ZTEXTREPLACEMENTENTRY (ZSHORTCUT TEXT, ZPHRASE TEXT, ZWASDELETED INTEGER);")
            check("空の表は空配列", try Sync.existing(database: database).isEmpty)
            try sql("INSERT INTO ZTEXTREPLACEMENTENTRY VALUES ('utage','UTAGE',0), ('deleted','Deleted',1), ('etax','e-Tax',NULL);")
            let before = try Data(contentsOf: database)
            let rows = try Sync.existing(database: database)
            let after = try Data(contentsOf: database)
            check("削除済みを除き読み取り専用で読む", Set(rows) == Set([Pair(shortcut: "utage", phrase: "UTAGE"), Pair(shortcut: "etax", phrase: "e-Tax")])
                  && after == before)
            let export = folder.appendingPathComponent("export/terms.plist")
            Sync.writeExport(candidates, to: export)
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: export), options: [], format: nil)
            check("書き出したplistを読み戻せる", plist as? [[String: String]] == candidates.map { ["shortcut": $0.shortcut, "phrase": $0.phrase] })
            state.verifiedAt = now
            state.verifiedOS = os
            state.testFailures = 2
            state.lastTestFailure = now.addingTimeInterval(-60)
            state.lastError = "試験の失敗"
            state.added = candidates
            let stateURL = folder.appendingPathComponent("state.json")
            Sync.saveState(state, to: stateURL)
            let restored = Sync.loadState(stateURL)
            check("状態を一時フォルダで保存・復元できる", restored.lastError == state.lastError && restored.added == candidates
                  && restored.lastSuccess == state.lastSuccess && restored.lastFailure == state.lastFailure
                  && restored.verifiedAt == state.verifiedAt && restored.verifiedOS == os
                  && restored.testFailures == 2 && restored.lastTestFailure == state.lastTestFailure)
            var changedOS = restored
            changedOS.invalidateVerification(currentOS: "new macOS")
            Sync.saveState(changedOS, to: stateURL)
            let reloaded = Sync.loadState(stateURL)
            check("OS変更で消した印を保存・復元できる", reloaded.verifiedAt == nil && reloaded.verifiedOS == nil)
            let legacyURL = folder.appendingPathComponent("legacy.json")
            try Data(#"{"lastSuccess":"2026-11-01T00:00:00Z","lastError":"old error","added":[{"shortcut":"utage","phrase":"UTAGE"}]}"#.utf8).write(to: legacyURL)
            let legacy = Sync.loadState(legacyURL)
            check("古い状態ファイルも既存項目を保って読める", legacy.lastSuccess != nil && legacy.lastError == "old error"
                  && legacy.added == [Pair(shortcut: "utage", phrase: "UTAGE")]
                  && legacy.verifiedAt == nil && legacy.verifiedOS == nil && legacy.testFailures == 0
                  && legacy.lastTestFailure == nil && action(legacy) == .liveTest)
        } catch { check("一時ファイルの試験: \(error)", false) }
        return passed
    }
}
