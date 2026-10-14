import Foundation
import AVFoundation

enum MeetingTests {
    static func run() -> Bool {
        var results: [(String, Bool)] = []
        do {
            var r = MeetingRecord(title: "保存障害テスト", meetingCode: "")
            r.utterances = [.init(id: "1", speaker: "テスト", start: 0, end: 1, text: "消してはいけない元の発言", source: "test")]
            var savedBody = ""
            try MeetingDelivery.checkpoint(record: &r) { _, body, _ in
                savedBody = body; return URL(string: "https://docs.google.com/document/d/test/edit")!
            }
            let ok = try MeetingDelivery.correct(record: &r) { record in
                record.utterances[0].text = "途中で変更された文"
                throw MeetingFailure.message("意図的なAI失敗")
            }
            results.append(("AI失敗前に原文を保存し途中の校正を破棄", !ok && savedBody.contains(r.utterances[0].text) && r.transcriptDocumentURL != nil && !r.warnings.isEmpty))
            try MeetingDelivery.checkpoint(record: &r) { _, _, _ in throw MeetingFailure.message("二重保存") }
            results.append(("保存済み原文を再作成しない", true))
            do {
                _ = try MeetingDelivery.correct(record: &r) { _ in throw Polisher.PolishError.cancelled }
                results.append(("キャンセルを成功扱いしない", false))
            } catch Polisher.PolishError.cancelled { results.append(("キャンセルを成功扱いしない", true)) }
        } catch { results.append(("原文先行保存: \(error)", false)) }
        var continuity = MeetingContinuity()
        results.append(("一時的なMeet表示欠落で停止しない", !continuity.shouldStop(current: "a", active: nil, now: 0)))
        results.append(("短い欠落から復帰したら会議を維持", !continuity.shouldStop(current: "a", active: "a", now: 4)))
        results.append(("復帰後は欠落の猶予をリセット", !continuity.shouldStop(current: "a", active: nil, now: 20)))
        results.append(("退出が継続したら録音停止", continuity.shouldStop(current: "a", active: nil, now: 26)))
        continuity.reset()
        results.append(("別会議へ切り替えたら結合しない", continuity.shouldStop(current: "a", active: "b", now: 30)))
        results.append(("前年比と増加率の意味変更を拒否", (try? MeetingCorrection.validateMoney("売上101.5%増", evidence: "売上は前年比101.5%")) == nil))
        results.append(("曖昧な増加表現を確定させない", (try? MeetingCorrection.validateMoney("売上101.5%増", evidence: "売上は101.5%の増")) == nil))
        results.append(("比率を別の値へ変えない", (try? MeetingCorrection.validateMoney("前年比1.5%", evidence: "前年比101.5%")) == nil))
        results.append(("比率の基準を保持する要約は受理", (try? MeetingCorrection.validateMoney("売上は前年比101.5%", evidence: "売上は前年比が101.5%です")) != nil))
        results.append(("ポイント差と増加率を混同しない", (try? MeetingCorrection.validateMoney("5%増", evidence: "5%ポイント増")) == nil))
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let a = directory.appendingPathComponent("a.wav"), b = directory.appendingPathComponent("b.wav"), output = directory.appendingPathComponent("combined.wav")
            try SpeechSegments.wav(Array(repeating: 0.2, count: 16000)).write(to: a)
            try SpeechSegments.wav(Array(repeating: 0.4, count: 16000)).write(to: b)
            try MeetingRecognition.combine([
                MeetingAudioCapture.Chunk(url: a, channel: .remote, startSeconds: 0, durationSeconds: 1),
                MeetingAudioCapture.Chunk(url: b, channel: .remote, startSeconds: 1.5, durationSeconds: 1)
            ], output: output)
            let file = try AVAudioFile(forReading: output, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let samples = buffer.floatChannelData![0]
            results.append(("音声結合で時刻の隙間を保持", file.length == 40000 && abs(samples[20000]) < 0.001 && samples[25000] > 0.39))
        } catch { results.append(("音声結合: \(error)", false)) }
        let u = MeetingUtterance(id: "発言1", speaker: "話者1（氏名未確認）", start: 12, end: 15, text: "確認は山田さんが明日までに行います。", source: "test")
        let short = MeetingUtterance(id: "短い", speaker: "A", start: 12, end: 13, text: "一部", source: "test")
        results.append(("一部だけの重なりで原文を落とさない", !MeetingMinutes.isCovered(u, by: [short])))
        results.append(("全区間を覆う置換を確認", MeetingMinutes.isCovered(u, by: [u])))
        let fragmented = (1...16).map { MeetingRecognition.Segment(start: 12, end: 14, speaker: "話者\($0)") }
        let attributed = MeetingRecognition.attribute([u], segments: fragmented, participantCount: 2)
        results.append(("過剰な話者推定を採用せず本文を一度だけ保持", attributed.count == 1 && attributed[0].text == u.text && attributed[0].speaker == "相手側（話者未確認）"))
        let stable = MeetingRecognition.attribute([u], segments: [.init(start: 12, end: 15, speaker: "話者1")], participantCount: 2)
        results.append(("安定した単独話者は本文を変えず付与", stable[0].speaker.contains("話者1") && stable[0].id == u.id))
        let mixed = MeetingRecognition.attribute([u], segments: [.init(start: 12, end: 13.5, speaker: "話者1"), .init(start: 13.5, end: 15, speaker: "話者2")])
        results.append(("区間内交代を一人へ誤帰属しない", mixed[0].speaker.contains("複数話者") && mixed[0].text == u.text))
        let epoch = Date(timeIntervalSince1970: 1000)
        let me = MeetingPresence.Participant(id: "self", name: "i-shot", isSelf: true, speaking: false)
        let other = MeetingPresence.Participant(id: "remote", name: "女性の参加アカウント", isSelf: false, speaking: false)
        let frames = (0...25).map { MeetingPresence(at: 1000 + Double($0), participants: [me, other], complete: true) }
        let remoteText = MeetingUtterance(id: "r", speaker: "未確認", start: 0, end: 25, text: "何時に帰る？", source: "remote")
        let accountResult = MeetingAccounts.apply([remoteText], frames: frames, startedAt: epoch)
        results.append(("二人会議の相手を参加アカウントに対応", accountResult[0].speaker == "女性の参加アカウント（Meet参加アカウント）" && accountResult[0].text == remoteText.text))
        var ownText = remoteText; ownText.source = "local"
        results.append(("自分のマイクを自己アカウントに対応", MeetingAccounts.apply([ownText], frames: frames, startedAt: epoch)[0].speaker.contains("i-shot")))
        results.append(("途中の情報欠落を名前で埋めない", MeetingAccounts.apply([remoteText], frames: [frames[0], frames[25]], startedAt: epoch)[0].speaker == "未確認"))
        var switched = frames
        for i in 12...25 { switched[i].participants[1].id = "new"; switched[i].participants[1].name = "次の参加者" }
        results.append(("区間内の参加者入替を一人へ帰属しない", MeetingAccounts.apply([remoteText], frames: switched, startedAt: epoch)[0].speaker == "未確認"))
        var multi = frames
        for i in multi.indices {
            multi[i].participants[1].speaking = true
            multi[i].participants.append(.init(id: "third", name: "別の参加者", isSelf: false, speaking: false))
        }
        results.append(("複数参加者では発話中アカウントを対応", MeetingAccounts.apply([remoteText], frames: multi, startedAt: epoch)[0].speaker.contains("女性の参加アカウント")))
        for i in multi.indices { multi[i].participants[2].speaking = true }
        results.append(("同時発話を一人へ帰属しない", MeetingAccounts.apply([remoteText], frames: multi, startedAt: epoch)[0].speaker == "未確認"))
        let incomplete = frames.map { MeetingPresence(at: $0.at, participants: $0.participants, complete: false) }
        results.append(("画面に一部の参加者しかない時は単独と決めない", MeetingAccounts.apply([remoteText], frames: incomplete, startedAt: epoch)[0].speaker == "未確認"))
        let officialSessions = [MeetingParticipantSession(id: "self", name: "i-shot", start: 1000, end: 1100), MeetingParticipantSession(id: "r", name: "相手", start: 1000, end: 1100)]
        results.append(("DOMなしでも公式入退室履歴で相手を対応", MeetingAccounts.applyOfficial([remoteText], sessions: officialSessions, ownName: "i-shot", startedAt: epoch)[0].speaker == "相手（Meet参加アカウント）"))
        results.append(("公式履歴でも本人未確認なら推測しない", MeetingAccounts.applyOfficial([remoteText], sessions: officialSessions, ownName: nil, startedAt: epoch)[0].speaker == "未確認"))
        let overlapping = officialSessions + [.init(id: "third", name: "第三者", start: 1010, end: 1015)]
        results.append(("短時間の第三者参加も一人と決めつけない", MeetingAccounts.applyOfficial([remoteText], sessions: overlapping, ownName: "i-shot", startedAt: epoch)[0].speaker == "未確認"))
        let gapSessions = [officialSessions[0], .init(id: "r", name: "相手", start: 1000, end: 1010), .init(id: "r", name: "相手", start: 1015, end: 1100)]
        results.append(("同一アカウントの退出間隔を埋めない", MeetingAccounts.applyOfficial([remoteText], sessions: gapSessions, ownName: "i-shot", startedAt: epoch)[0].speaker == "未確認"))
        do {
            let candidate = MeetingMinutes.Summary(summary: [.init(text: "確認は山田さんが行う", evidence: [u.id])], decisions: [], tasks: [], unresolved: [.init(text: "未決", evidence: [u.id], open_question_quote: "確認は山田さんが明日までに行います。")])
            let filtered = try MeetingMinutes.validatedItems(String(decoding: JSONEncoder().encode(candidate), as: UTF8.self), originals: [u])
            results.append(("不適格候補だけを除外し検証済み要約を保持", filtered.summary.count == 1 && filtered.unresolved.isEmpty && filtered.excludedCount == 1))
            var reviewRecord = MeetingRecord(title: "テスト", meetingCode: ""); reviewRecord.utterances = [u]
            let rendered = MeetingMinutes.render(record: reviewRecord, summaries: [filtered])
            results.append(("除外を明記し該当なしと誤表示しない", rendered.contains("候補1件") && rendered.contains(u.text) && !rendered.contains("該当する明確な発言なし")))
        } catch { results.append(("項目別検証: \(error)", false)) }
        let valid = #"{"summary":[],"decisions":[],"tasks":[{"text":"山田さんが明日までに確認","evidence":["発言1"]}],"unresolved":[]}"#
        do {
            let summary = try MeetingMinutes.validated(valid, ids: ["発言1"])
            results.append(("有効な発言根拠を受理", summary.tasks.count == 1))
            results.append(("存在しない根拠を拒否", (try? MeetingMinutes.validated(valid, ids: ["別の発言"])) == nil))
            let missing = valid.replacingOccurrences(of: "[\"発言1\"]", with: "[]")
            results.append(("根拠なしの要約を拒否", (try? MeetingMinutes.validated(missing, ids: ["発言1"])) == nil))
            var r = MeetingRecord(title: "合成テスト", meetingCode: ""); r.utterances = [u]
            let body = MeetingMinutes.render(record: r, summaries: [summary])
            results.append(("話者と根拠時刻と全文を保持", body.contains("00:00:12") && body.contains(u.text) && body.contains(u.speaker)))
            let items = (0..<30).map { n in MeetingUtterance(id: "\(n)", speaker: "A", start: Double(n), end: Double(n + 1), text: String(repeating: "文", count: 1000), source: "test") }
            let groups = MeetingMinutes.batches(items)
            results.append(("長い会議の全発言を順序通り保持", groups.count == 3 && groups.flatMap { $0 } == items))
            try r.save(); let loaded = try MeetingRecord.load(r.directory)
            results.append(("再開用データの保存と復元", loaded.utterances == r.utterances && loaded.id == r.id))
            r.generatedTitle = "広告予算と公開日程の確認"
            try r.nameFolder()
            let renamed = try MeetingRecord.load(r.directory)
            results.append(("フォルダ名変更後も会議IDと保存先を復元", renamed.id == r.id && renamed.directory == r.directory && r.directory.lastPathComponent.contains("広告予算")))
            r.title = ""
            results.append(("予定名が空なら余分な区切りを省略", !r.displayTitle.contains("｜｜") && r.displayTitle.hasSuffix("｜広告予算と公開日程の確認")))
            try FileManager.default.removeItem(at: r.directory)
        } catch { results.append(("例外: \(error)", false)) }
        var interrupted = MeetingRecord(title: "停止テスト", meetingCode: "")
        interrupted.captureError = "マイク再接続失敗"
        do {
            _ = try MeetingMinutes.generate(record: interrupted, cancelled: { false }, progress: { _ in })
            results.append(("発話なしを捏造せず録音中断原因を表示", false))
        } catch {
            results.append(("発話なしを捏造せず録音中断原因を表示", error.localizedDescription.contains("マイク再接続失敗")))
        }
        let correctionOriginal = [MeetingUtterance(id: "a", speaker: "本人", start: 0, end: 1, text: "33万円ではなく30万3000円に提供してください", source: "local")]
        let good = MeetingCorrection.Item(id: "a", text: "33万円ではなく30万3000円に訂正してください", uncertain: [])
        results.append(("文脈校正で数字と発言IDを保持", (try? MeetingCorrection.validate([good], originals: correctionOriginal)) != nil))
        let changed = MeetingCorrection.Item(id: "a", text: "30万円に訂正してください", uncertain: [])
        results.append(("校正による金額変更を拒否", (try? MeetingCorrection.validate([changed], originals: correctionOriginal)) == nil))
        results.append(("校正による発言欠落を拒否", (try? MeetingCorrection.validate([], originals: correctionOriginal)) == nil))
        results.append(("要約で30万3000円を30万円に丸めない", (try? MeetingCorrection.validateMoney("30万円に決定", evidence: "30万3000円に訂正")) == nil))
        results.append(("根拠通りの金額を受理", (try? MeetingCorrection.validateMoney("30万3000円に決定", evidence: "33万円でなく30万3000円")) != nil))
        results.append(("明示的な金額訂正の提供を修復", MeetingCorrection.repairExplicitCorrection("修正がありまして、33万円でなく、税込み30万3000円に提供してください。") == "修正がありまして、33万円でなく、税込み30万3000円に訂正してください。"))
        let ordinary = "33万円でなく30万円に提供してください。"
        results.append(("通常の提供依頼を勝手に訂正へ変えない", MeetingCorrection.repairExplicitCorrection(ordinary) == ordinary))
        // Response formatting and recovery must not weaken the evidence checks.
        do {
            let wrapped = "説明です。\n```json\n" + valid + "\n```\n以上です。"
            results.append(("説明・コード枠付きJSONを受理", try MeetingMinutes.validated(wrapped, ids: ["発言1"]).tasks.count == 1))
            results.append(("一行コード枠付きJSONを受理", try MeetingMinutes.validated("```json " + valid + " ```", ids: ["発言1"]).tasks.count == 1))
            results.append(("途中で切れたJSONを拒否", (try? MeetingMinutes.validated(String(valid.dropLast()), ids: ["発言1"])) == nil))
            results.append(("複数の回答JSONを拒否", (try? MeetingMinutes.validated(valid + "\n" + valid, ids: ["発言1"])) == nil))
            results.append(("欠落した項目を空配列で勝手に補わない", (try? MeetingMinutes.validated("{}", ids: ["発言1"])) == nil))
            let braces = valid.replacingOccurrences(of: "山田さんが明日までに確認", with: #"文字列内の } と \"引用\" を確認"#)
            results.append(("JSON文字列内の括弧と引用符を保持", (try? MeetingMinutes.validated("説明\n" + braces, ids: ["発言1"])) != nil))
            var calls = 0
            let repaired = try MeetingMinutes.validatedResponse(stage: "自己テスト", cancelled: { false }, request: { attempt in
                calls += 1; return attempt == 0 ? "{broken" : valid
            }, validate: { try MeetingMinutes.validated($0, ids: ["発言1"]) })
            results.append(("形式不備から自動再生成して復帰", calls == 2 && repaired.tasks.count == 1))
            calls = 0
            let exhausted: MeetingMinutes.Summary? = try? MeetingMinutes.validatedResponse(stage: "自己テスト", cancelled: { false }, request: { _ in
                calls += 1; return "{}"
            }, validate: { try MeetingMinutes.validated($0, ids: ["発言1"]) })
            results.append(("不正な回答を成功扱いせず3回で打切り", exhausted == nil && calls == 3))
            calls = 0
            let stopped: MeetingMinutes.Summary? = try? MeetingMinutes.validatedResponse(stage: "自己テスト", cancelled: { calls > 0 }, request: { _ in
                calls += 1; return "{}"
            }, validate: { try MeetingMinutes.validated($0, ids: ["発言1"]) })
            results.append(("キャンセル後は再生成しない", stopped == nil && calls == 1))
            calls = 0
            let denied: MeetingMinutes.Summary? = try? MeetingMinutes.validatedResponse(stage: "自己テスト", cancelled: { false }, request: { _ in
                calls += 1; throw Polisher.PolishError.maxLoginRequired
            }, validate: { try MeetingMinutes.validated($0, ids: ["発言1"]) })
            results.append(("認証エラーを形式再試行に含めない", denied == nil && calls == 1))
            calls = 0
            let evidenceRetry = try MeetingMinutes.validatedResponse(stage: "自己テスト", cancelled: { false }, request: { attempt in
                calls += 1; return attempt == 0 ? valid.replacingOccurrences(of: "発言1", with: "架空ID") : valid
            }, validate: { try MeetingMinutes.validated($0, ids: ["発言1"]) })
            results.append(("根拠不一致も拒否して再生成", evidenceRetry.tasks.count == 1 && calls == 2))
        } catch { results.append(("JSON復帰テスト: \(error)", false)) }
        let place = MeetingAddress.reference("愛知県トヨタ市美雪本町12番地の3")
        results.append(("カナ市名から正式な町名・読みを取得", place.contains("愛知県豊田市御幸本町") && place.contains("ミユキホンマチ")))
        results.append(("市名なしで町名を全国から確定しない", MeetingAddress.reference("みゆきほんまち").isEmpty))
        results.append(("市名による町域候補の限定", !MeetingAddress.reference("愛知県豊田市").contains("安城市")))
        let open = MeetingUtterance(id: "a", speaker: "本人", start: 0, end: 1, text: "会場はまだ決まっていません。", source: "local")
        let genuine = #"{"summary":[],"decisions":[],"tasks":[],"unresolved":[{"text":"会場未定","evidence":["a"],"open_question_quote":"会場はまだ決まっていません"}]}"#
        results.append(("参加者が発言した未決事項は保持", (try? MeetingMinutes.validated(genuine, ids: ["a"], originals: [open])) != nil))
        let mistaken = MeetingUtterance(id: "a", speaker: "本人", start: 0, end: 1, text: "健康案の構成をお願いします。", source: "local")
        results.append(("認識ミスを未決事項へ転記しない", (try? MeetingMinutes.validated(genuine, ids: ["a"], originals: [mistaken])) == nil))
        let noQuote = #"{"summary":[],"decisions":[],"tasks":[],"unresolved":[{"text":"健康案の意味確認が必要","evidence":["a"]}]}"#
        results.append(("認識の不確かさだけで未決事項を捏造しない", (try? MeetingMinutes.validated(noQuote, ids: ["a"], originals: [mistaken])) == nil))
        let typoOriginal = MeetingUtterance(id: "a", speaker: "本人", start: 0, end: 1, text: "5時脱時を確認する作業です。", source: "local")
        let typoCorrection = MeetingCorrection.Item(id: "a", text: "誤字脱字を確認する作業です。", uncertain: [])
        results.append(("語を誤認識した数字だけ限定して修復", (try? MeetingCorrection.validate([typoCorrection], originals: [typoOriginal])) != nil))
        let clockOriginal = MeetingUtterance(id: "a", speaker: "本人", start: 0, end: 1, text: "5時に確認する作業です。", source: "local")
        results.append(("実際の時刻の数字は削除できない", (try? MeetingCorrection.validate([typoCorrection], originals: [clockOriginal])) == nil))
        results.append(("同額の言い直しは認識不明として検出", MeetingCorrection.ambiguousAmount("税込33万円ではなくて税込33万円に訂正")))
        results.append(("異なる金額への訂正は保持", !MeetingCorrection.ambiguousAmount("33万円ではなく30万3000円に訂正")))
        results.append(("解消済みの訂正説明は要確認に載せない", !MeetingCorrection.unresolvedNote("美雪本町を御幸本町に訂正。音の一致を確認。")))
        results.append(("未解決の人名は要確認に保持", MeetingCorrection.unresolvedNote("人名の漢字確認が必要です")))
        results.append(("税別から税込への同額訂正は不明扱いしない", !MeetingCorrection.ambiguousAmount("税別33万円ではなく税込33万円です")))
        results.append(("工場の商品を作る製作を維持", MeetingCorrection.contextualTerms("工場の商品制作費と広告制作費") == "工場の商品製作費と広告制作費"))
        let placeSource = MeetingUtterance(id: "a", speaker: "本人", start: 0, end: 1, text: "住所は三浴本町12番地の3です。", source: "test")
        let verifiedPlace = MeetingAddress.Resolution(original: "三浴本町", town: "御幸本町", municipality: "愛知県豊田市", reading: "ミユキホンマチ")
        let proposed = MeetingCorrection.Item(id: "a", text: placeSource.text, uncertain: [], places: [verifiedPlace])
        do {
            let fixed = try MeetingCorrection.resolvePlaces([proposed], originals: [placeSource], context: "愛知県豊田市の話です。")
            results.append(("照合済み町名を本文へ即時反映し番地を保持", fixed[0].text == "住所は御幸本町12番地の3です。"))
        } catch { results.append(("地名反映: \(error)", false)) }
        results.append(("別自治体への地名補正は拒否", (try? MeetingAddress.verify(verifiedPlace, original: placeSource.text, context: "愛知県安城市の話です。")) == nil))
        let invented = MeetingAddress.Resolution(original: "三浴本町", town: "御幸架空町", municipality: "愛知県豊田市", reading: "ミユキホンマチ")
        results.append(("AIが作った架空地名を拒否", (try? MeetingAddress.verify(invented, original: placeSource.text, context: "豊田市")) == nil))
        let wrongReading = MeetingAddress.Resolution(original: "三浴本町", town: "御幸本町", municipality: "愛知県豊田市", reading: "サンヨクホンマチ")
        results.append(("正式町名でも読みが一致しなければ拒否", (try? MeetingAddress.verify(wrongReading, original: placeSource.text, context: "豊田市")) == nil))
        results.forEach { print("\($0.1 ? "PASS" : "FAIL"): \($0.0)") }
        return results.allSatisfy { $0.1 }
    }
}
