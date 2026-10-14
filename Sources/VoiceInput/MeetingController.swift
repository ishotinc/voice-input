import Foundation

/// Main-thread coordinator. Each meeting owns its own capture, records, chunks and work queue.
/// Releasing the physical microphone makes room for the next recording immediately, even if
/// the old session is still draining ASR or waiting for its serialized minutes/export job.
final class MeetingController {
    typealias State = MeetingSession.State
    private var active: MeetingSession?
    private var processing: [MeetingSession] = []
    private var reservedIDs: Set<String> = []
    private var attemptedUploads: [String: Date] = [:]
    private var retryTimer: Timer?
    private var lastStatus = "会議モード・待機中"
    private(set) var latestURL: URL?
    var canStartBackground: (() -> Bool)?
    var onChange: (() -> Void)?
    var onRecordingFailure: ((String) -> Void)?
    var blocksRecording: Bool { active != nil }
    var isBusy: Bool { blocksRecording || !processing.isEmpty }
    var processingCount: Int { processing.count }
    var state: State { active?.state ?? (processing.isEmpty ? .idle : .finishing) }
    var elapsed: String { active?.elapsed ?? processing.first?.elapsed ?? "" }
    var status: String {
        if let active { return active.status + (processing.isEmpty ? "" : "・議事録\(processing.count)件を処理中") }
        if let first = processing.first { return "議事録\(processing.count)件: " + first.status + "（次の録音ができます）" }
        return lastStatus
    }
    func observeSharedScreen(text: String, at: Double) { active?.observeSharedScreen(text: text, at: at) }
    init() {
        latestURL = MeetingRecord.recent().first(where: { $0.documentURL != nil || $0.revisionDocumentURL != nil }).flatMap { ($0.revisionDocumentURL ?? $0.documentURL).flatMap(URL.init(string:)) }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, self.processing.isEmpty, self.canStartBackground?() != false,
                  MeetingGoogleDrive.shared.isAuthenticated,
                  let record = MeetingRecord.recent().filter({
                      !self.reservedIDs.contains($0.id) && $0.status != "saved" &&
                      (FileManager.default.fileExists(atPath: $0.directory.appendingPathComponent("minutes.txt").path) || $0.status == "processing" || $0.status == "uploading")
                  }).min(by: { (self.attemptedUploads[$0.id] ?? .distantPast) < (self.attemptedUploads[$1.id] ?? .distantPast) }) else { return }
            self.retry(record)
        }
    }
    private func attach(_ session: MeetingSession, recordID: String? = nil) {
        session.onCaptureReleased = { [weak self, weak session] in
            guard let self, let session, self.active === session else { return }
            self.active = nil
            self.processing.append(session)
            self.onChange?()
        }
        session.onChange = { [weak self, weak session] in
            guard let self, let session else { return }
            if session.state == .idle {
                let failedCapture = self.active === session && session.status.hasPrefix("要確認:")
                if self.active === session { self.active = nil }
                self.processing.removeAll { $0 === session }
                if let recordID { self.reservedIDs.remove(recordID) }
                self.lastStatus = session.status
                if let url = session.latestURL { self.latestURL = url }
                if failedCapture { self.onRecordingFailure?(session.status) }
            }
            self.onChange?()
        }
    }
    func begin(title: String, meetingCode: String, browserPID: Int32, settings: Settings, remoteSpeakerCount: Int? = nil) {
        guard !blocksRecording else { return }
        let session = MeetingSession()
        guard adoptRecording(session) else { return }
        session.begin(title: title, meetingCode: meetingCode, browserPID: browserPID, settings: settings, remoteSpeakerCount: remoteSpeakerCount)
    }
    private func adoptRecording(_ session: MeetingSession) -> Bool {
        guard !blocksRecording else { return false }
        active = session
        reservedIDs.insert(session.id)
        attach(session, recordID: session.id)
        return true
    }
    /// Exercises the same microphone-release/completion callbacks used by real sessions.
    /// Delayed jobs and out-of-order completions must not release another meeting's microphone.
    static func runConcurrencyTests() -> Bool {
        let controller = MeetingController()
        controller.retryTimer?.invalidate()
        let first = MeetingSession(), second = MeetingSession(), third = MeetingSession()
        var results: [(String, Bool)] = []
        results.append(("録音中の二重開始を拒否", controller.adoptRecording(first) && !controller.adoptRecording(second)))
        first.onCaptureReleased?()
        results.append(("議事録処理中も次の録音を開始", controller.processingCount == 1 && !controller.blocksRecording && controller.adoptRecording(second)))
        // The first job completes while the second still owns the microphone.
        first.onChange?()
        results.append(("前会議の完了で次の録音を解除しない", controller.active === second && controller.processingCount == 0 && controller.reservedIDs == [second.id]))
        second.onCaptureReleased?()
        _ = controller.adoptRecording(third)
        third.onCaptureReleased?()
        results.append(("複数会議を独立したIDで保持", controller.processingCount == 2 && controller.reservedIDs == [second.id, third.id] && !controller.blocksRecording))
        third.onChange?()
        results.append(("後の会議が先に完了しても前会議を保持", controller.processingCount == 1 && controller.processing.first === second && controller.reservedIDs == [second.id]))
        second.onChange?()
        results.append(("全件終了後に待機へ復帰", !controller.isBusy && controller.reservedIDs.isEmpty))
        results.forEach { print("\($0.1 ? "PASS" : "FAIL"): \($0.0)") }
        return results.allSatisfy { $0.1 }
    }
    func stop() { active?.stop() }
    func observeParticipants(_ frames: [MeetingPresence]) { active?.observeParticipants(frames) }
    func setSelfDisplayName(_ name: String) { active?.setSelfDisplayName(name) }
    func retryLatest() {
        guard let record = MeetingRecord.recent().first(where: { $0.status != "saved" && $0.endedAt != nil && !reservedIDs.contains($0.id) }) else { return }
        retry(record)
    }
    private func retry(_ record: MeetingRecord) {
        guard !reservedIDs.contains(record.id) else { return }
        reservedIDs.insert(record.id); attemptedUploads[record.id] = Date()
        let session = MeetingSession(id: record.id)
        processing.append(session); attach(session, recordID: record.id)
        session.retry(record)
    }
    func prepareForTermination(completion: @escaping () -> Void) {
        retryTimer?.invalidate()
        for session in processing { session.prepareForTermination(completion: {}) }
        if let active { active.prepareForTermination(completion: completion) }
        else { completion() }
    }
    static func replayLocalTest(directory: URL) throws { try MeetingSession.replayLocalTest(directory: directory) }
}
