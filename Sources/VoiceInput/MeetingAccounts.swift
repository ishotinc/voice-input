import Foundation

struct MeetingPresence: Codable {
    struct Participant: Codable {
        var id: String
        var name: String
        var isSelf: Bool
        var speaking: Bool
    }
    var at: Double
    var participants: [Participant]
    var complete: Bool
}

enum MeetingAccounts {
    // Never use a roster from the end of a meeting to label earlier speech.
    static func apply(_ utterances: [MeetingUtterance], frames: [MeetingPresence], startedAt: Date) -> [MeetingUtterance] {
        let base = startedAt.timeIntervalSince1970
        let ordered = frames.sorted { $0.at < $1.at }
        return utterances.map { original in
            guard original.source == "local" || original.source == "remote" else { return original }
            let lo = base + original.start, hi = base + original.end
            let samples = ordered.filter { $0.at >= lo - 1 && $0.at <= hi + 1 }
            guard let first = samples.first, let last = samples.last, first.at <= lo + 2, last.at >= hi - 2,
                  zip(samples, samples.dropFirst()).allSatisfy({ $1.at - $0.at <= 3 }) else { return original }
            var ids = Set<String>(), names = Set<String>(), uncertain = false
            for frame in samples {
                let own = frame.participants.filter { $0.isSelf }
                guard own.count == 1 else { uncertain = true; continue }
                if original.source == "local" {
                    ids.insert(own[0].id); names.insert(own[0].name); continue
                }
                guard frame.complete, Set(frame.participants.map(\.id)).count == frame.participants.count else { uncertain = true; continue }
                let remote = frame.participants.filter { !$0.isSelf }
                let candidates = remote.count == 1 ? remote : remote.filter { $0.speaking }
                // No active marker in a multi-person call is a gap, not proof of silence.
                guard candidates.count == 1 else { uncertain = true; continue }
                ids.insert(candidates[0].id); names.insert(candidates[0].name)
            }
            guard !uncertain, ids.count == 1, names.count == 1, let name = names.first, !name.isEmpty else { return original }
            var result = original
            result.speaker = name + (original.source == "remote" ? "（Meet参加アカウント）" : "（自分・Meet参加アカウント）")
            return result
        }
    }
}

struct MeetingParticipantSession: Codable {
    var id: String
    var name: String
    var start: Double
    var end: Double
}

extension MeetingAccounts {
    static func applyOfficial(_ utterances: [MeetingUtterance], sessions: [MeetingParticipantSession], ownName: String?, startedAt: Date) -> [MeetingUtterance] {
        guard let ownName, !ownName.isEmpty else { return utterances }
        let ownIDs = Set(sessions.filter { $0.name == ownName }.map(\.id))
        guard ownIDs.count == 1, let ownID = ownIDs.first else { return utterances }
        func covers(_ rows: [MeetingParticipantSession], _ lo: Double, _ hi: Double) -> Bool {
            var cursor = lo
            for row in rows.sorted(by: { $0.start < $1.start }) where row.end > cursor {
                if row.start > cursor { return false }
                cursor = max(cursor, row.end)
                if cursor >= hi { return true }
            }
            return false
        }
        return utterances.map { u in
            guard u.source == "local" || u.source == "remote" else { return u }
            let lo = startedAt.timeIntervalSince1970 + u.start, hi = startedAt.timeIntervalSince1970 + u.end
            let rows = sessions.filter { $0.start < hi && $0.end > lo }
            let own = rows.filter { $0.id == ownID }
            guard covers(own, lo, hi) else { return u }
            let candidates = u.source == "local" ? own : rows.filter { $0.id != ownID }
            guard Set(candidates.map(\.id)).count == 1, Set(candidates.map(\.name)).count == 1,
                  let name = candidates.first?.name, covers(candidates, lo, hi) else { return u }
            var result = u
            result.speaker = name + (u.source == "local" ? "（自分・Meet参加アカウント）" : "（Meet参加アカウント）")
            return result
        }
    }
}
