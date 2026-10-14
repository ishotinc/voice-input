import Foundation

/// A durable, coalescing raw-transcript outbox, independent from ASR/AI and record-folder renames.
final class MeetingTranscriptOutbox {
    struct Payload: Codable {
        let meetingID: String
        let title: String
        let body: String
        let segmentIDs: [String]
    }
    static let shared = MeetingTranscriptOutbox()
    private let directory = Paths.settings.deletingLastPathComponent().appendingPathComponent("transcript-outbox")
    private let disk = DispatchQueue(label: "voiceinput.transcript.disk", qos: .utility)
    private let network = DispatchQueue(label: "voiceinput.transcript.google", qos: .utility)
    private var scheduled = Set<String>()
    private var nextAttempt: [String: Date] = [:]
    private var timer: DispatchSourceTimer?
    func start() {
        disk.async {
            guard self.timer == nil else { return }
            try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let timer = DispatchSource.makeTimerSource(queue: self.disk)
            timer.schedule(deadline: .now(), repeating: 30)
            timer.setEventHandler { self.scan() }; self.timer = timer; timer.resume()
        }
    }
    static func payload(_ record: MeetingRecord) -> Payload? {
        let utterances = record.provisional ?? record.uncorrected ?? record.utterances
        guard !utterances.isEmpty else { return nil }
        let header = "未校正の文字起こし\n会議ID: \(record.id)\nAI校正・要約前の原記録です。\n\n"
        let body = header + utterances.map {
            "[\($0.id)] \(MeetingMinutes.timestamp($0.start))–\(MeetingMinutes.timestamp($0.end)) \($0.speaker)（\($0.source)）\n\($0.text)\n\n"
        }.joined()
        return Payload(meetingID: record.id, title: record.displayTitle + "｜未校正の文字起こし", body: body, segmentIDs: utterances.map(\.id))
    }
    func offer(_ record: MeetingRecord) {
        guard let payload = Self.payload(record) else { return }
        disk.async {
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let url = self.file(payload.meetingID)
                try JSONEncoder().encode(payload).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                self.scan()
            } catch { Log.write("原文Google送信待ちの保存に失敗。会議の原文はmeeting.jsonに保持") }
        }
    }
    private func file(_ id: String) -> URL { directory.appendingPathComponent(ClientDictionary.digest(id) + ".json") }
    private func scan() {
        guard MeetingGoogleDrive.shared.isAuthenticated else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let payload = try? JSONDecoder().decode(Payload.self, from: data),
                  !scheduled.contains(payload.meetingID), nextAttempt[payload.meetingID, default: .distantPast] <= Date() else { continue }
            scheduled.insert(payload.meetingID)
            network.async {
                var success = false
                do {
                    _ = try MeetingGoogleDrive.shared.syncTranscript(title: payload.title, body: payload.body, meetingID: payload.meetingID)
                    success = true
                    Log.write("原文Google保存: segments=\(payload.segmentIDs.count)")
                } catch { Log.write("原文Google送信待ち: ローカル保存を維持") }
                let saved = success
                self.disk.async {
                    if saved, (try? Data(contentsOf: file)) == data { try? FileManager.default.removeItem(at: file) }
                    self.scheduled.remove(payload.meetingID)
                    self.nextAttempt[payload.meetingID] = Date().addingTimeInterval(30)
                }
            }
        }
    }
}

enum TranscriptAppend {
    enum Action: Equatable { case complete, append(String), fork }
    static func normalized(_ text: String) -> String { text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines) }
    static func decide(actual: String, desired: String, previousHash: String) -> Action {
        let actual = normalized(actual), desired = normalized(desired)
        if actual == desired { return .complete }
        guard ClientDictionary.digest(actual) == previousHash, desired.hasPrefix(actual) else { return .fork }
        return .append(String(desired.dropFirst(actual.count)))
    }
}
