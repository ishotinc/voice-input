import Foundation

enum JevTests {
    static func run() -> Bool {
        var ok = true
        func check(_ title: String, _ condition: Bool) { print((condition ? "PASS: " : "FAIL: ") + title); ok = ok && condition }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("jev-test-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var config = JevSettings(); config.sharingAccepted = true; config.dictation = true
        let budget = JevBudget(url: temp.appendingPathComponent("usage.json"))
        let questions: [String: [String: Any]] = ["x": ["type": "choice", "instructions": "選択", "criteria": ["keep": "原文", "unknown": "不明"]]]
        let mock: JevClient.Transport = { request, _ in
            let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let questions = object["questions"] as! [String: [String: Any]]
            var answers: [String: Any] = [:]
            for (id, question) in questions {
                let criteria = question["criteria"] as! [String: String]
                let selected = criteria["keep"] == nil ? "clear" : "keep"
                answers[id] = ["type": "choice", "choice": selected, "confidence": 0.99,
                    "probabilities": Dictionary(uniqueKeysWithValues: criteria.keys.map { ($0, $0 == selected ? 1.0 : 0.0) })]
            }
            return (try JSONSerialization.data(withJSONObject: ["model": JevClient.model, "answers": answers, "usage": ["input_tokens": 100]]), 200)
        }
        let client = JevClient(budget: budget, key: { "synthetic-test-key" }, transport: mock)
        do {
            _ = try client.choose(state: ["original": "架空の短文"], questions: questions, session: "test", meeting: false, settings: config, cancelled: { false })
            check("使用量はAPIのinput_tokensを集計", abs((budget.usage()?.confirmed ?? -1) - 100 * JevBudget.price) < 1e-10)
            check("完了した予約は実費へ精算", budget.usage()?.reserved == 0)
        } catch { check("API形式と使用量", false) }
        var limited = config; limited.monthlyUSD = Double(JevBudget.reservationTokens) * JevBudget.price * 1.5; limited.meetingUSD = limited.monthlyUSD
        let restricted = JevBudget(url: temp.appendingPathComponent("limited.json"))
        do {
            _ = try restricted.reserve(session: "one", meeting: true, settings: limited)
            let reopened = JevBudget(url: temp.appendingPathComponent("limited.json"))
            do { _ = try reopened.reserve(session: "two", meeting: false, settings: limited); check("結果不明の予約を再起動後も上限へ算入", false) }
            catch { check("結果不明の予約を再起動後も上限へ算入", true) }
        } catch { check("上限予約", false) }
        for code in [401, 429, 500] {
            let failing = JevClient(budget: budget, key: { "test" }, transport: { _, _ in (Data(), code) })
            do { _ = try failing.choose(state: [:], questions: questions, session: "failure", meeting: false, settings: config, cancelled: { false }); check("HTTP \(code) で原文経路へ", false) }
            catch { check("HTTP \(code) で原文経路へ", true) }
        }
        let malformed = JevClient(budget: budget, key: { "test" }, transport: { _, _ in (Data("{}".utf8), 200) })
        do { _ = try malformed.choose(state: [:], questions: questions, session: "bad", meeting: false, settings: config, cancelled: { false }); check("不正応答拒否", false) }
        catch { check("不正応答拒否", true) }
        var disabled = config; disabled.sharingAccepted = false
        var sent = false
        let never = JevClient(budget: budget, key: { "test" }, transport: { _, _ in sent = true; throw JevClient.Failure.timeout })
        _ = try? never.choose(state: [:], questions: questions, session: "disabled", meeting: false, settings: disabled, cancelled: { false })
        check("送信同意なしではHTTPを呼ばない", !sent)
        let fixture = CorrectionCandidates.Lexicon("せいさく /制作/製作/政策/\n")
        check("手動登録せず同一読みの候補を得る", fixture.alternatives("製作").contains("制作"))
        let original = "広告の製作費は33万円ではありません。"
        let spans = CorrectionCandidates.make(original, lexicon: fixture)
        check("候補は原文の位置に紐づく", spans.contains { $0.original == "製作" })
        let span = CorrectionCandidates.Span(id: "s", location: 0, length: 2, original: "33", choices: [.init(id: "bad", text: "30", evidence: "test", proper: false)])
        do { _ = try CorrectionCandidates.apply(["s": "bad"], spans: [span], original: "33万円"); check("金額変更を拒否", false) }
        catch { check("金額変更を拒否", true) }
        check("否定と依頼・決定を保護", CorrectionCandidates.protected("決定ではありません") != CorrectionCandidates.protected("決定です"))
        let evaluator = IncrementalCorrection(sessionID: "shadow", client: client)
        let value = evaluator.evaluate(text: "広告の製作をお願いします。", segment: "s1", revision: .init(asr: 1, context: 1), context: "動画", dictionary: "", meeting: false, settings: config)
        check("比較評価では原文を変更せずClaudeへ渡す", !value.adopted && value.needsClaude && value.text == "広告の製作をお願いします。")
        var advisory = config; advisory.shadow = false
        let suggestionClient = JevClient(budget: budget, key: { "synthetic" }, transport: { request, _ in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let qs = body["questions"] as! [String: [String: Any]]
            var answers: [String: Any] = [:]
            for (id, q) in qs {
                let criteria = q["criteria"] as! [String: String]
                let selected = criteria.first(where: { $0.value.hasPrefix("制作（") })?.key ?? (criteria["keep"] == nil ? "clear" : "keep")
                answers[id] = ["type": "choice", "choice": selected, "confidence": 0.99,
                    "probabilities": Dictionary(uniqueKeysWithValues: criteria.keys.map { ($0, $0 == selected ? 1.0 : 0.0) })]
            }
            return (try JSONSerialization.data(withJSONObject: ["model": JevClient.model, "answers": answers, "usage": ["input_tokens": 100]]), 200)
        })
        let advisor = IncrementalCorrection(sessionID: "advisory", client: suggestionClient)
        let proposed = advisor.evaluate(text: "広告の製作をお願いします。", segment: "a", revision: .init(asr: 1, context: 1), context: "広告動画", dictionary: "", meeting: false, settings: advisory)
        check("Jev候補をClaudeへ引き継ぐ", proposed.advice.contains("制作") && proposed.needsClaude)
        check("未評価のJev候補だけで本文を置換しない", !proposed.adopted && proposed.text == "広告の製作をお願いします。")
        let cached = advisor.evaluate(text: "広告の製作をお願いします。", segment: "a", revision: .init(asr: 1, context: 1), context: "広告動画", dictionary: "", meeting: false, settings: advisory)
        check("キャッシュも候補を保持する", !cached.advice.isEmpty && cached.advice == proposed.advice)
        evaluator.cancel()
        check("終了後の応答を反映しない", !evaluator.isCurrent(segment: "s1", request: value.requestID, revision: value.revision))
        let old = "原文\n最初の発言", new = old + "\n次の発言"
        check("Googleの未送信末尾だけを追記", TranscriptAppend.decide(actual: old + "\n", desired: new, previousHash: ClientDictionary.digest(old)) == .append("\n次の発言"))
        check("Google応答不明後の再送で重複しない", TranscriptAppend.decide(actual: new, desired: new, previousHash: ClientDictionary.digest(old)) == .complete)
        check("ユーザー編集を検出して別版へ", TranscriptAppend.decide(actual: old + "手動編集", desired: new, previousHash: ClientDictionary.digest(old)) == .fork)
        check("既存設定へJev無効の既定値を補完", (try? JSONDecoder().decode(Settings.self, from: Data("{}".utf8)))?.jev.dictation == false)
        return ok
    }
}
