import Foundation

/// A missing DOM button for one poll is not evidence that a call ended.
struct MeetingContinuity {
    private var missingSince: Double?
    mutating func shouldStop(current: String, active: String?, now: Double) -> Bool {
        if active == current { missingSince = nil; return false }
        // A different confirmed call must never be merged into the old recording.
        if active != nil { missingSince = nil; return true }
        if missingSince == nil { missingSince = now }
        return now - missingSince! >= 6
    }
    mutating func reset() { missingSince = nil }
}
