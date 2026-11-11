import AppKit

/// AI 補正の失敗と再接続の結果を出す小さな窓。前面のアプリを奪わないので、押したあと元のアプリへ貼り付けられる。
final class AIStatusPanel {
    struct Action {
        let title: String
        let handler: () -> Void
    }

    private final class Target: NSObject {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func fire() { handler() }
    }

    private var panel: NSPanel?
    private var targets: [Target] = []
    private var autoClose: DispatchWorkItem?

    /// autoCloseAfter を渡すと、その秒数で閉じる（録音前の短い知らせ）。
    func show(message: String, actions: [Action], autoCloseAfter: TimeInterval? = nil) {
        close()
        let label = NSTextField(wrappingLabelWithString: message)
        label.preferredMaxLayoutWidth = 320
        label.widthAnchor.constraint(equalToConstant: 320).isActive = true
        let stack = NSStackView(views: [label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        for action in actions {
            let target = Target(action.handler)
            targets.append(target)
            let button = NSButton(title: action.title, target: target, action: #selector(Target.fire))
            button.bezelStyle = .rounded
            button.widthAnchor.constraint(equalToConstant: 320).isActive = true
            stack.addArrangedSubview(button)
        }
        let size = stack.fittingSize
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "音声入力"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = stack
        if let frame = NSScreen.main?.visibleFrame {
            window.setFrameTopLeftPoint(NSPoint(x: frame.maxX - window.frame.width - 16, y: frame.maxY - 8))
        }
        panel = window
        window.orderFrontRegardless()
        if let autoCloseAfter {
            let work = DispatchWorkItem { [weak self] in self?.close() }
            autoClose = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoCloseAfter, execute: work)
        }
    }

    func close() {
        autoClose?.cancel()
        autoClose = nil
        panel?.close()
        panel = nil
        targets = []
    }

    /// 見た目の確認用。画面を撮らずに、窓の中身だけを PNG に書き出す。
    func renderContent(to url: URL) -> Bool {
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
