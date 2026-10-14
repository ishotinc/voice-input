import AppKit

/// Progress exists only in the existing status item. No windows, screen captures, or text persistence.
final class MenuProgress {
    struct Display {
        let symbol: String
        let title: String
        let tooltip: String
    }
    var onChange: ((Display) -> Void)?
    private var timer: Timer?
    private var started = Date()
    private var destination = ""
    private var message = ""
    private var detail = ""
    private var generation = 0

    func begin(destination: String) {
        timer?.invalidate(); generation += 1
        started = Date(); self.destination = destination
        message = "文字起こし中"; detail = "停止した音声を文字にしています。"
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }
    func update(_ message: String, detail: String) {
        self.message = message; self.detail = detail; tick()
    }
    private func tick() {
        let elapsed = Int(Date().timeIntervalSince(started))
        let title = elapsed < 60 ? "\(elapsed)s" : "\(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
        onChange?(Display(symbol: elapsed % 2 == 0 ? "hourglass.tophalf.filled" : "hourglass.bottomhalf.filled",
                          title: title, tooltip: "\(message) · 経過\(elapsed)秒\n\(detail)\n入力先: \(destination)"))
    }
    func finish(error: String? = nil) {
        timer?.invalidate(); timer = nil
        generation += 1
        if let error {
            onChange?(Display(symbol: "exclamationmark.circle", title: "", tooltip: "確認が必要です\n" + error))
        } else {
            let token = generation
            onChange?(Display(symbol: "checkmark", title: "", tooltip: "貼り付け完了"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.generation == token else { return }
                self.onChange?(Display(symbol: "mic", title: "", tooltip: "音声入力・待機中"))
            }
        }
    }
    func reset() {
        timer?.invalidate(); timer = nil; generation += 1
    }
    static func selfTest() -> Bool {
        let windowsBefore = NSApplication.shared.windows.count
        let progress = MenuProgress()
        var display: Display?
        progress.onChange = { display = $0 }
        progress.begin(destination: "test")
        let working = display?.title == "0s" && display?.symbol.hasPrefix("hourglass") == true
        progress.update("AI", detail: "2/3")
        let detail = display?.tooltip.contains("2/3") == true
        progress.finish(error: "network")
        let failure = display?.symbol == "exclamationmark.circle"
        progress.finish()
        let complete = display?.symbol == "checkmark"
        progress.reset()
        return working && detail && failure && complete && NSApplication.shared.windows.count == windowsBefore
    }
}
