import AppKit

/// 設定ウィンドウが表示する今の値。AppDelegate が組み立てる。
struct SettingsSnapshot {
    var idle: Bool
    var useScreenContext: Bool
    var shareScreenContext: Bool
    var contextStatus: String
    var hasClientFolder: Bool
    var provider: AIProvider
    var providerTitles: [String]
    var aiStatus: String
    var claudeKeyTitle: String
    var openAIKeyTitle: String
    var clientFolder: String
    var clientStatus: String
    var meetingStatus: String
    var googleTitle: String
    var googleEnabled: Bool
}

/// 設定ウィンドウから頼む操作。中身は AppDelegate の既存の処理を呼ぶ。
enum SettingsCommand {
    case toggleScreenContext, toggleCloudContext, editStyle, registerName, openTerms, showPermissions, revealApp, openLog
    case selectProvider(AIProvider), reconnectAI, setClaudeKey, setOpenAIKey, showJev
    case chooseClientFolder, clearClientFolder
    case connectGoogle, openMeetingData
}

/// メニューバーのアプリには「ファイル」メニューが無いので、⌘W をここで受ける。
private final class SettingsNSWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class SettingsPane: NSViewController {
    private let content: NSView
    init(title: String, content: NSView) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func loadView() { view = content }
}

/// ⌘, で開く設定。チェックと選択はその場で保存する（適用ボタンは置かない）。
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private final class Handler: NSObject {
        let run: (Any?) -> Void
        init(_ run: @escaping (Any?) -> Void) { self.run = run }
        @objc func fire(_ sender: Any?) { run(sender) }
    }

    private static let paneSize = NSSize(width: 560, height: 330)

    private let snapshot: () -> SettingsSnapshot
    private let perform: (SettingsCommand) -> Void
    private var handlers: [Handler] = []
    private var refreshers: [(SettingsSnapshot) -> Void] = []
    private var timer: Timer?

    init(snapshot: @escaping () -> SettingsSnapshot, perform: @escaping (SettingsCommand) -> Void) {
        self.snapshot = snapshot
        self.perform = perform
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let window = SettingsNSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        for (title, symbol, rows) in [("一般", "gearshape", generalRows()), ("AI", "sparkles", aiRows()),
                                      ("顧客資料", "folder", clientRows()), ("会議", "person.2", meetingRows())] {
            let item = NSTabViewItem(viewController: SettingsPane(title: title, content: pane(rows)))
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        window.setContentSize(Self.paneSize)
        window.center()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        // 再接続・Google連携・辞書の準備は裏で終わるので、開いているあいだだけ表示を追う。
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let now = snapshot()
        refreshers.forEach { $0(now) }
    }

    private func run(_ command: SettingsCommand) {
        perform(command)
        refresh()
    }

    // MARK: - タブの中身

    private func generalRows() -> [[NSView]] {
        [
            [caption("入力画面"), checkbox("入力画面を参考にする（端末内）", .toggleScreenContext, on: \.useScreenContext, enabled: \.idle)],
            [caption(""), value(\.contextStatus)],
            [caption("文体"), button("仕上げの文体を設定…", .editStyle, enabled: \.idle)],
            [caption("言葉"), row(button("用語辞書を開く", .openTerms), button("人名の読みを登録…", .registerName, enabled: { $0.idle && $0.hasClientFolder }))],
            [caption("権限"), button("権限を確認…", .showPermissions)],
            [caption("アプリ"), row(button("Finder で表示", .revealApp), button("ログを開く", .openLog))],
        ]
    }

    private func aiRows() -> [[NSView]] {
        [
            [caption("接続先"), providerPopup()],
            [caption("接続状態"), value(\.aiStatus)],
            [caption(""), button("AIに再接続", .reconnectAI, enabled: \.idle)],
            [caption("APIキー"), row(button(titled: \.claudeKeyTitle, .setClaudeKey, enabled: \.idle), button(titled: \.openAIKeyTitle, .setOpenAIKey, enabled: \.idle))],
            [caption("画面"), checkbox("画面の参考情報もAIに送る", .toggleCloudContext, on: \.shareScreenContext, enabled: \.idle)],
            [caption("Jev"), button("Jevの設定…", .showJev)],
        ]
    }

    private func clientRows() -> [[NSView]] {
        [
            [caption("フォルダ"), value(\.clientFolder, truncatesMiddle: true)],
            [caption("状態"), value(\.clientStatus)],
            [caption(""), row(button("顧客資料フォルダを選ぶ…", .chooseClientFolder, enabled: \.idle),
                              button("選択を解除", .clearClientFolder, enabled: { $0.idle && $0.hasClientFolder }))],
        ]
    }

    private func meetingRows() -> [[NSView]] {
        [
            [caption("状態"), value(\.meetingStatus)],
            [caption("Google"), button(titled: \.googleTitle, .connectGoogle, enabled: \.googleEnabled)],
            [caption("会議データ"), button("Finder で開く", .openMeetingData)],
        ]
    }

    // MARK: - 部品

    private func pane(_ rows: [[NSView]]) -> NSView {
        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        let container = NSView(frame: NSRect(origin: .zero, size: Self.paneSize))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.paneSize.width),
            container.heightAnchor.constraint(equalToConstant: Self.paneSize.height),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])
        return container
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.isEmpty ? "" : text + ":")
        label.alignment = .right
        return label
    }

    private func row(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private func value(_ text: KeyPath<SettingsSnapshot, String>, truncatesMiddle: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 400).isActive = true
        if truncatesMiddle {
            label.maximumNumberOfLines = 1
            label.cell?.lineBreakMode = .byTruncatingMiddle
        }
        refreshers.append { label.stringValue = $0[keyPath: text]; label.toolTip = truncatesMiddle ? $0[keyPath: text] : nil }
        return label
    }

    private func handler(_ run: @escaping (Any?) -> Void) -> Handler {
        let handler = Handler(run)
        handlers.append(handler)
        return handler
    }

    private func button(_ title: String, _ command: SettingsCommand, enabled: ((SettingsSnapshot) -> Bool)? = nil) -> NSButton {
        let target = handler { [weak self] _ in self?.run(command) }
        let button = NSButton(title: title, target: target, action: #selector(Handler.fire(_:)))
        button.bezelStyle = .rounded
        if let enabled { refreshers.append { button.isEnabled = enabled($0) } }
        return button
    }

    private func button(titled title: KeyPath<SettingsSnapshot, String>, _ command: SettingsCommand, enabled: ((SettingsSnapshot) -> Bool)? = nil) -> NSButton {
        let view = button("", command, enabled: enabled)
        refreshers.append { view.title = $0[keyPath: title] }
        return view
    }

    private func checkbox(_ title: String, _ command: SettingsCommand, on: KeyPath<SettingsSnapshot, Bool>, enabled: ((SettingsSnapshot) -> Bool)? = nil) -> NSButton {
        let target = handler { [weak self] _ in self?.run(command) }
        let box = NSButton(checkboxWithTitle: title, target: target, action: #selector(Handler.fire(_:)))
        refreshers.append { box.state = $0[keyPath: on] ? .on : .off; if let enabled { box.isEnabled = enabled($0) } }
        return box
    }

    private func providerPopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        let target = handler { [weak self] sender in
            guard let index = (sender as? NSPopUpButton)?.indexOfSelectedItem, AIProvider.allCases.indices.contains(index) else { return }
            self?.run(.selectProvider(AIProvider.allCases[index]))
        }
        popup.target = target
        popup.action = #selector(Handler.fire(_:))
        refreshers.append { now in
            if popup.itemTitles != now.providerTitles {
                popup.removeAllItems()
                popup.addItems(withTitles: now.providerTitles)
            }
            if let index = AIProvider.allCases.firstIndex(of: now.provider), popup.indexOfSelectedItem != index { popup.selectItem(at: index) }
            popup.isEnabled = now.idle
        }
        return popup
    }

    /// 見た目の確認用。架空の値で各タブの中身を PNG に書き出す（キーチェーンも画面も使わない）。
    static func renderSample(to folder: URL) -> Bool {
        let sample = SettingsSnapshot(
            idle: true, useScreenContext: true, shareScreenContext: true, contextStatus: "画面参照: 128文字（AI校正へ送信）",
            hasClientFolder: true, provider: .claude,
            providerTitles: AIProvider.allCases.map(\.menuTitle), aiStatus: "Claude Code Max に接続できました",
            claudeKeyTitle: "Claude APIキーを設定…", openAIKeyTitle: "OpenAI APIキーを設定…",
            clientFolder: "~/Documents/company/clients/very-long-client-folder-name/documents/minutes",
            clientStatus: "顧客辞書: 準備済み", meetingStatus: "会議モード・待機中", googleTitle: "Googleドライブを連携…", googleEnabled: true)
        let controller = SettingsWindowController(snapshot: { sample }, perform: { _ in })
        guard let tabs = controller.window?.contentViewController as? NSTabViewController else { return false }
        var saved = true
        for (index, item) in tabs.tabViewItems.enumerated() {
            tabs.selectedTabViewItemIndex = index
            guard let view = item.viewController?.view else { return false }
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = folder.appendingPathComponent("settings-\(index)-\(item.label).png")
            saved = saved && (rep.representation(using: .png, properties: [:]).map { (try? $0.write(to: url)) != nil } ?? false)
        }
        return saved
    }
}
