import Foundation

/// Main-thread cue scheduling. A stopped or replaced recording must never beep later.
final class CueSchedule {
    private var generation = 0
    func cancel() { generation += 1 }
    func schedule(after delay: TimeInterval, action: @escaping () -> Void) {
        cancel()
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == token else { return }
            action()
        }
    }
}
