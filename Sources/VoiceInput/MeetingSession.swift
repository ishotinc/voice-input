import AppKit
import AVFoundation

/// Owns a meeting independently from dictation. All UI state is on main; disk and ASR on work queue.
final class MeetingSession: @unchecked Sendable {
    let id: String
    init(id: String = UUID().uuidString) { self.id = id }
    enum State { case idle, starting, recording, finishing }
    private(set) var state: State = .idle
    private(set) var status = "会議モード・待機中"
    private(set) var latestURL: URL?
    var onCaptureReleased: (() -> Void)?
    private static let finishingQueue = DispatchQueue(label: "voiceinput.meeting.finishing", qos: .utility)
    var onChange: (() -> Void)?
    private var terminationCompletion: (() -> Void)?
    private var capture: MeetingAudioCapture?
    private var record: MeetingRecord?
    private let work = DispatchQueue(label: "com.ishot.voice-input.meeting", qos: .utility)
    private var chunks: [MeetingAudioCapture.Chunk] = [] // work queue only
    private var settings = Settings()
    private var progressTimer: Timer?
    private var participantTimer: Timer?
    private let participantWork = DispatchQueue(label: "voiceinput.meeting.participants")
    private var participantRequestRunning = false
    private var sharedScreens: [(at: Double, text: String)] = [] // work queue only; never saved
    func observeSharedScreen(text: String, at: Double) {
        guard !text.isEmpty else { return }
        work.async {
            guard let record = self.record, at >= record.startedAt.timeIntervalSince1970,
                  self.sharedScreens.last?.at != at - record.startedAt.timeIntervalSince1970 else { return }
            self.sharedScreens.append((at - record.startedAt.timeIntervalSince1970, String(text.prefix(6000))))
            if self.sharedScreens.count > 480 { self.sharedScreens.removeFirst(self.sharedScreens.count - 480) }
        }
    }
    private var started = Date()
    private let cancellationLock = NSLock()
    private var cancellation = false
    var isBusy: Bool { state != .idle }
    var elapsed: String { MeetingMinutes.timestamp(Date().timeIntervalSince(started)) }
    var isCancelled: Bool { cancellationLock.lock(); defer { cancellationLock.unlock() }; return cancellation }
    private func setCancelled(_ value: Bool) { cancellationLock.lock(); cancellation = value; cancellationLock.unlock() }
    /// Replays existing local chunks through production ASR and minutes generation without
    /// modifying the source record or creating a Google document.
    static func replayLocalTest(directory: URL) throws {
        let controller = MeetingSession()
        controller.settings = Settings.load()
        var record = try MeetingRecord.load(directory)
        record.utterances = []; record.completedFiles = []; record.provisional = nil
        let chunks = try MeetingAudioCapture.loadPersistedChunks(directory: directory.appendingPathComponent("audio"))
        for chunk in chunks where chunk.channel == .local {
            try controller.recognize(chunk, into: &record)
        }
        print("保存済みマイク音声の再認識: \(record.utterances.count)区間")
        for i in record.utterances.indices { record.utterances[i].id = "発言\(i + 1)" }
        let text = try MeetingMinutes.generate(record: record, cancelled: { false }, progress: { print($0) })
        guard text.contains("根拠:") && text.contains("話者") else { throw MeetingFailure.message("議事録の検証に失敗") }
        print("PASS: 保存済み実音声→通常モード文字起こし→Claude Max議事録生成（原記録変更・Google書込なし）")
    }

    /// Resume only the failed summary/export step; keep completed ASR and correction.
    static func recoverSummary(directory: URL) throws {
        var r = try MeetingRecord.load(directory)
        guard r.status == "failed", (r.error ?? "").hasPrefix("会議議事録"), !r.utterances.isEmpty else {
            throw MeetingFailure.message("議事録生成で失敗し文字起こしが残る記録だけを対象にします。")
        }
        let backup = directory.appendingPathComponent("meeting-before-summary-recovery.json")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: directory.appendingPathComponent("meeting.json"), to: backup)
        }
        do {
            r.officialParticipantSessions = try MeetingGoogleDrive.shared.participantSessions(meetingCode: r.meetingCode, startedAt: r.startedAt, endedAt: r.endedAt ?? Date())
            r.utterances = MeetingAccounts.applyOfficial(r.utterances, sessions: r.officialParticipantSessions ?? [], ownName: r.selfDisplayName, startedAt: r.startedAt)
            print("Meet参加履歴: \(r.officialParticipantSessions?.count ?? 0)セッション、表示名対応: \(r.utterances.filter { $0.speaker.contains("Meet参加アカウント") }.count)区間")
        } catch { r.warnings.append("参加履歴を取得できず、保存済みの話者表示を保持しました。") }
        try r.save()
        let transcript = directory.appendingPathComponent("transcript.txt")
        try MeetingMinutes.transcript(record: r, notice: "保存済み文字起こし。AI要約とは別に保持しています。").write(to: transcript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transcript.path)
        let text = try MeetingMinutes.generate(record: r, cancelled: { false }, progress: { print($0) })
        r.generatedTitle = text.components(separatedBy: "\n").first
        let body = directory.appendingPathComponent("minutes.txt")
        try text.write(to: body, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: body.path)
        try r.nameFolder()
        try r.save()
        let url = try MeetingGoogleDrive.shared.export(title: r.displayTitle, body: text, meetingID: r.id)
        r.documentURL = url.absoluteString; r.status = "saved"; r.error = nil
        try r.save()
        print("PASS: 保存・本文読み戻し完了 " + url.absoluteString)
    }

    static func reviseTest(directory: URL, reRecognize: Bool = true, remoteSpeakerCount: Int? = nil) throws {
        let session = MeetingSession()
        session.settings = Settings.load()
        var record = try MeetingRecord.load(directory)
        if let count = remoteSpeakerCount { record.remoteSpeakerCount = count }
        if reRecognize {
            record.utterances = []; record.completedFiles = []; record.provisional = nil
            let chunks = try MeetingAudioCapture.loadPersistedChunks(directory: directory.appendingPathComponent("audio"))
            for chunk in chunks { try session.recognize(chunk, into: &record) }
        } else { record.utterances = record.provisional ?? record.uncorrected ?? record.utterances }
        let savedChunks = try MeetingAudioCapture.loadPersistedChunks(directory: directory.appendingPathComponent("audio"))
        let remote = try MeetingRecognition.transcribeSpeakers(chunks: savedChunks, directory: directory, settings: session.settings,
            originals: record.utterances.filter { $0.source == "remote" }, speakerCount: record.remoteSpeakerCount,
            participantCount: record.participantNames?.count, cancelled: { false }, progress: { print($0) })
        record.utterances = record.utterances.filter { $0.source == "local" } + remote
        record.warnings = ["保存された録音と文字起こしを修正版で再処理しました。"]
        record.utterances.sort { $0.start < $1.start }
        for index in record.utterances.indices { record.utterances[index].id = "発言\(index + 1)" }
        record.provisional = record.utterances
        print("発話あり: マイク\(record.utterances.filter { $0.source == "local" }.count)区間、相手\(record.utterances.filter { $0.source == "remote" }.count)区間")
        try MeetingCorrection.correct(record: &record, cancelled: { false }, progress: { print($0) })
        let text = try MeetingMinutes.generate(record: record, cancelled: { false }, progress: { print($0) })
        record.generatedTitle = text.components(separatedBy: "\n").first
        record.recognitionVersion = 3
        record.recognitionModel = session.settings.resolvedMeetingModel.lastPathComponent
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for (name, data) in [("revised-meeting.json", try encoder.encode(record)), ("revised-minutes.txt", Data(text.utf8))] {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        print("再処理完了: " + directory.appendingPathComponent("revised-minutes.txt").path)
    }
    private func update(_ message: String) {
        DispatchQueue.main.async { self.status = message; self.onChange?() }
    }
    func begin(title: String, meetingCode: String, browserPID: pid_t, settings: Settings, remoteSpeakerCount: Int? = nil) {
        guard !isBusy else { return }
        state = .starting; status = "会議の録音を準備中"; self.settings = settings; setCancelled(false)
        started = Date(); onChange?()
        work.async {
            do {
                var r = MeetingRecord(title: title, meetingCode: meetingCode)
                r.id = self.id
                r.recognitionVersion = 3
                r.recognitionModel = settings.resolvedMeetingModel.lastPathComponent
                r.remoteSpeakerCount = remoteSpeakerCount
                r.clientFolder = settings.selectedClientFolder; r.model = settings.polishModel
                r.warnings = ["ブラウザの別タブの音も録音対象です。相手側の表示名はMeetの参加アカウント情報と時刻が対応した場合に記載します。"]
                try r.save(); self.record = r; self.chunks = []
                let capture = MeetingAudioCapture(directory: r.directory.appendingPathComponent("audio"), browserPID: browserPID, onChunk: { [weak self] chunk in self?.received(chunk) }, onError: { [weak self] error in
                    guard let self else { return }
                    self.work.async {
                        self.record?.captureError = error.localizedDescription
                        self.record?.warnings.append("録音中のエラー: \(error.localizedDescription)")
                        try? self.record?.save()
                    }
                    DispatchQueue.main.async { if self.state == .recording { self.stop() } }
                })
                DispatchQueue.main.async {
                    self.capture = capture
                    Task {
                        do {
                            try await capture.start()
                            if let completion = self.terminationCompletion {
                                self.terminationCompletion = nil
                                _ = await capture.stop(); completion(); return
                            }
                            self.work.async {
                                if let actual = capture.recordingStartedAt { self.record?.startedAt = actual; try? self.record?.save() }
                            }
                            self.state = .recording; self.status = "会議を録音中"; self.onChange?()
                            self.refreshParticipants()
                            self.participantTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.refreshParticipants() }
                            self.progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.onChange?() }
                        } catch {
                            if let completion = self.terminationCompletion {
                                self.terminationCompletion = nil; _ = await capture.stop(); completion(); return
                            }
                            let saved = await capture.stop()
                            self.work.async {
                                self.chunks = saved
                                self.record?.status = "failed"; self.record?.endedAt = Date(); self.record?.error = error.localizedDescription
                                try? self.record?.save()
                                self.end(error: error)
                            }
                        }
                    }
                }
            } catch { self.end(error: error) }
        }
    }
    func observeParticipants(_ frames: [MeetingPresence]) {
        guard state == .recording else { return }
        work.async {
            guard var r = self.record else { return }
            let last = r.participantTimeline?.last?.at ?? r.startedAt.timeIntervalSince1970 - 1
            let fresh = frames.filter { $0.at.isFinite && $0.at > last && $0.at <= Date().timeIntervalSince1970 + 1 && $0.participants.count <= 100 }
                .sorted { $0.at < $1.at }
            guard !fresh.isEmpty else { return }
            r.participantTimeline = (r.participantTimeline ?? []) + fresh
            self.record = r
        }
    }
    func setSelfDisplayName(_ name: String) {
        guard state == .recording else { return }
        work.async {
            self.record?.selfDisplayName = String(name.prefix(100))
            if let name = self.record?.selfDisplayName {
                for i in self.record!.utterances.indices where self.record!.utterances[i].source == "local" { self.record!.utterances[i].speaker = name }
            }
        }
    }
    private func refreshParticipants() {
        guard state == .recording, !participantRequestRunning, MeetingGoogleDrive.shared.isAuthenticated else { return }
        participantRequestRunning = true
        work.async {
            guard let record = self.record else { DispatchQueue.main.async { self.participantRequestRunning = false }; return }
            let id = record.id, code = record.meetingCode
            self.participantWork.async {
                do {
                    let names = try MeetingGoogleDrive.shared.activeParticipantNames(meetingCode: code)
                    self.work.async {
                        guard self.record?.id == id else { return }
                        self.record?.participantNames = names
                        // A joined call with exactly one active participant identifies our own microphone.
                        if names.count == 1 && self.record?.selfDisplayName == nil { self.record?.selfDisplayName = names[0] }
                        if let name = self.record?.selfDisplayName {
                            for i in self.record!.utterances.indices where self.record!.utterances[i].source == "local" { self.record!.utterances[i].speaker = name }
                        }
                        try? self.record?.save()
                    }
                    Log.write("Meet参加者情報取得: \(names.count)人")
                } catch { Log.write("Meet参加者情報取得失敗: \(error.localizedDescription)") }
                DispatchQueue.main.async { self.participantRequestRunning = false }
            }
        }
    }
    private func received(_ chunk: MeetingAudioCapture.Chunk) {
        work.async {
            self.chunks.append(chunk)
            do {
                guard var record = self.record else { return }
                // Persist manifest BEFORE recognition. A crash never loses the location of captured audio.
                try self.saveChunks(record: record)
                try self.recognize(chunk, into: &record)
                self.record = record; try record.save()
                MeetingTranscriptOutbox.shared.offer(record)

            } catch {
                self.record?.warnings.append("録音区間の文字起こし未完了: \(chunk.url.lastPathComponent)")
                self.record?.error = error.localizedDescription; try? self.record?.save()
            }
        }
    }
    private func recognize(_ chunk: MeetingAudioCapture.Chunk, into record: inout MeetingRecord) throws {
        if (record.completedFiles ?? []).contains(chunk.url.lastPathComponent) { return }
        let text: String
        do { text = try MeetingSpeech.transcribe(chunk.url, settings: settings) }
        catch Transcriber.TranscribeError.failed(let code, let reason) where code == -1 && reason.contains("異常な反復") {
            let warning = "文字起こし要確認: \(chunk.url.lastPathComponent)（\(Int(chunk.startSeconds))秒から）。再認識でも反復が残るため本文に採用せず、原音を保持しています。"
            if !record.warnings.contains(warning) { record.warnings.append(warning) }
            record.completedFiles = (record.completedFiles ?? []) + [chunk.url.lastPathComponent]
            Log.write("会議の反復区間を要確認として保持、他区間の処理を継続")
            return
        }
        if !text.isEmpty { record.utterances.append(MeetingUtterance(id: UUID().uuidString, speaker: chunk.channel == .local ? (record.selfDisplayName ?? "自分（マイク）") : "相手側（話者未確認）", start: chunk.startSeconds, end: chunk.startSeconds + chunk.durationSeconds, text: text, source: chunk.channel.rawValue)) }
        record.completedFiles = (record.completedFiles ?? []) + [chunk.url.lastPathComponent]
    }
    struct SavedChunk: Codable { var file: String; var channel: String; var start: Double; var duration: Double }
    private func saveChunks(record: MeetingRecord) throws {
        let saved = chunks.map { SavedChunk(file: $0.url.lastPathComponent, channel: $0.channel == .local ? "local" : "remote", start: $0.startSeconds, duration: $0.durationSeconds) }
        try JSONEncoder().encode(saved).write(to: record.directory.appendingPathComponent("chunks.json"), options: .atomic)
    }
    func stop() {
        guard state == .recording, let capture else { return }
        participantTimer?.invalidate(); participantTimer = nil
        state = .finishing; status = "録音を保存中"; progressTimer?.invalidate(); onChange?()
        Task {
            let all = await capture.stop()
            let endedAt = Date()
            self.capture = nil
            self.onCaptureReleased?()
            self.work.async {
                self.chunks = all
                self.record?.endedAt = endedAt; self.record?.status = "processing"
                do {
                    if let r = self.record { try self.saveChunks(record: r); try r.save() }
                    self.enqueueFinish()
                } catch { self.end(error: error) }
            }
        }
    }
    private func finish() throws {
        defer { sharedScreens.removeAll() }
        guard var r = record else { return }
        if isCancelled { throw Polisher.PolishError.cancelled }
        var bodyURL = r.directory.appendingPathComponent("minutes.txt")
        if !FileManager.default.fileExists(atPath: bodyURL.path) {
            if r.recognitionVersion != 3 { r.utterances = []; r.provisional = nil; r.completedFiles = []; r.recognitionVersion = 3; r.recognitionModel = settings.resolvedMeetingModel.lastPathComponent }
            if let original = r.provisional { r.utterances = original }
            for chunk in chunks {
                if isCancelled { throw Polisher.PolishError.cancelled }
                try recognize(chunk, into: &r)
            }
            r.provisional = r.utterances
            record = r; try r.save()
            var official: [GoogleMeetingEntry] = []
            if MeetingGoogleDrive.shared.isAuthenticated {
                update("Meetの話者情報を確認中")
                do { official = try MeetingGoogleDrive.shared.fetchTranscript(meetingCode: r.meetingCode, startedAt: r.startedAt, endedAt: r.endedAt ?? Date()) }
                catch { Log.write("Meet公式文字起こし取得失敗: \(error.localizedDescription)"); r.warnings.append("Meet公式の文字起こしを取得できませんでした（\(error.localizedDescription)）。ローカル音声を使用します。") }
            }
            if !official.isEmpty {
                r.utterances = official.map { MeetingUtterance(id: UUID().uuidString, speaker: $0.speaker, start: max(0, $0.start.timeIntervalSince(r.startedAt)), end: max(0, $0.end.timeIntervalSince(r.startedAt)), text: $0.text, source: "Meet公式") }
                let missing = (r.provisional ?? []).filter { original in
                    !MeetingMinutes.isCovered(original, by: r.utterances)
                }
                r.utterances += missing
                r.warnings.append("Meetで文字起こしが有効だった範囲です。会議全体が含まれるか確認してください。")
            } else {
                update("録音から話者を確認中")
                if MeetingGoogleDrive.shared.isAuthenticated {
                    do { r.officialParticipantSessions = try MeetingGoogleDrive.shared.participantSessions(meetingCode: r.meetingCode, startedAt: r.startedAt, endedAt: r.endedAt ?? Date()) }
                    catch { r.warnings.append("Meet参加履歴を取得できないため、取得済みの話者情報を使用します。") }
                }
                let screenAttributed = MeetingAccounts.apply(r.utterances, frames: r.participantTimeline ?? [], startedAt: r.startedAt)
                let accounted = MeetingAccounts.applyOfficial(screenAttributed, sessions: r.officialParticipantSessions ?? [], ownName: r.selfDisplayName, startedAt: r.startedAt)
                let originals = accounted.filter { $0.source == "remote" }
                let remote: [MeetingUtterance]
                if originals.allSatisfy({ $0.speaker.hasSuffix("（Meet参加アカウント）") }) {
                    remote = originals
                } else {
                    remote = try MeetingRecognition.transcribeSpeakers(chunks: chunks, directory: r.directory, settings: settings,
                        originals: originals, speakerCount: r.remoteSpeakerCount, participantCount: r.participantNames?.count,
                        cancelled: { self.isCancelled }, progress: update)
                }
                r.utterances = accounted.filter { $0.source == "local" } + remote
                r.utterances = MeetingAccounts.apply(r.utterances, frames: r.participantTimeline ?? [], startedAt: r.startedAt)
                r.utterances = MeetingAccounts.applyOfficial(r.utterances, sessions: r.officialParticipantSessions ?? [], ownName: r.selfDisplayName, startedAt: r.startedAt)
                r.warnings.append("話者判定は文字起こし区間単位です。区間内の交代や不安定な推定は未確定として残し、発言本文を重複させません。")
                r.warnings.append("話者番号は声の特徴から推定したものです。氏名・話者の統合や分割は要確認です。同時発話は正しく分けられない場合があります。")
            }
            r.utterances.sort { $0.start < $1.start }
            for i in r.utterances.indices { r.utterances[i].id = "発言\(i + 1)" }
            record = r; try r.save()
            try MeetingMinutes.transcript(record: r, notice: "校正・要約前の録音中文字起こしです。").write(to: r.directory.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: r.directory.appendingPathComponent("transcript.txt").path)
            if isCancelled { throw Polisher.PolishError.cancelled }
            do {
                update("校正前の文字起こしをGoogleへ保存中")
                let rawPayload = MeetingTranscriptOutbox.payload(r)
                try MeetingDelivery.checkpoint(record: &r) { _, _, _ in
                    guard let payload = rawPayload else { throw JevClient.Failure.response }
                    return try MeetingGoogleDrive.shared.syncTranscript(title: payload.title, body: payload.body, meetingID: payload.meetingID)
                }
                if let link = r.transcriptDocumentURL, let url = URL(string: link) {
                    DispatchQueue.main.async { self.latestURL = url }
                }
            } catch { r.warnings.append("校正前のGoogle保存に失敗しました。原文をMacに保持し、処理後に保存を再試行します。") }
            record = r; try r.save()
            let corrected = try MeetingDelivery.correct(record: &r) {
                try MeetingCorrection.correct(record: &$0, cancelled: { self.isCancelled }, progress: self.update, screenReferences: self.sharedScreens)
                self.sharedScreens.removeAll()
            }
            record = r; try r.save()
            let text = corrected ? try MeetingMinutes.generate(record: r, cancelled: { self.isCancelled }, progress: update)
                : MeetingMinutes.transcript(record: r, notice: "AI校正・要約は未完了です。以下は未校正の文字起こしです。")
            r.generatedTitle = text.components(separatedBy: "\n").first
            record = r; try r.save()
            try text.write(to: bodyURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bodyURL.path)
        }
        if isCancelled { throw Polisher.PolishError.cancelled }
        try r.nameFolder(); record = r
        bodyURL = r.directory.appendingPathComponent("minutes.txt")
        update("Googleドキュメントへ保存中")
        r.status = "uploading"; record = r; try r.save()
        let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd"
        let url = try MeetingGoogleDrive.shared.export(title: r.displayTitle, body: String(contentsOf: bodyURL, encoding: .utf8), meetingID: r.id)
        r.documentURL = url.absoluteString; r.status = "saved"; r.error = nil; record = r; try r.save()
        DispatchQueue.main.async { self.latestURL = url }
    }
    func retry(_ r: MeetingRecord) {
        state = .finishing; status = "保存済み音声から再開中"; setCancelled(false); started = Date(); onChange?()
        work.async {
            self.record = r; self.settings = Settings.load()
            do {
                let durable = try MeetingAudioCapture.loadPersistedChunks(directory: r.directory.appendingPathComponent("audio"))
                if !durable.isEmpty { self.chunks = durable }
                else {
                    let saved = try JSONDecoder().decode([SavedChunk].self, from: Data(contentsOf: r.directory.appendingPathComponent("chunks.json")))
                    self.chunks = try saved.map {
                        guard $0.file == URL(fileURLWithPath: $0.file).lastPathComponent, !$0.file.contains("..") else { throw MeetingFailure.message("録音ファイルの参照が不正です。") }
                        return MeetingAudioCapture.Chunk(url: r.directory.appendingPathComponent("audio").appendingPathComponent($0.file), channel: $0.channel == "local" ? .local : .remote, startSeconds: $0.start, durationSeconds: $0.duration)
                    }
                }
                if self.record?.endedAt == nil { self.record?.endedAt = r.startedAt.addingTimeInterval(self.chunks.map { $0.startSeconds + $0.durationSeconds }.max() ?? 0) }
                self.enqueueFinish()
            } catch { self.end(error: error) }
        }
    }
    private func enqueueFinish() {
        update("議事録の作成待ち")
        Self.finishingQueue.async {
            self.work.sync {
                do { try self.finish(); self.end(error: nil) }
                catch { self.end(error: error) }
            }
        }
    }
    private func end(error: Error?) {
        if let error { record?.error = error.localizedDescription; record?.status = "failed"; try? record?.save() }
        DispatchQueue.main.async {
            self.state = .idle; self.capture = nil; self.progressTimer?.invalidate(); self.progressTimer = nil
            self.status = error.map { "要確認: " + $0.localizedDescription } ?? "議事録をGoogleドキュメントに保存しました"
            self.onChange?()
        }
    }
    /// Termination is deferred by the app until capture has flushed. Pending work survives on disk.
    func prepareForTermination(completion: @escaping () -> Void) {
        setCancelled(true)
        if state == .starting { terminationCompletion = completion; return }
        if let capture {
            Task { _ = await capture.stop(); completion() }
        } else { completion() }
    }
}
