import Foundation

/// Main-thread ownership. A later recording permanently retires earlier auto-paste.
struct DictationQueue {
    private(set) var generation = 0
    private var pending = Set<Int>()
    var pendingCount: Int { pending.count }

    mutating func beginRecording() { generation += 1 }
    mutating func enqueue() -> Int {
        pending.insert(generation)
        return generation
    }
    mutating func complete(_ job: Int) { pending.remove(job) }
    func mayAutoPaste(_ job: Int) -> Bool { job == generation && pending.contains(job) }
}
