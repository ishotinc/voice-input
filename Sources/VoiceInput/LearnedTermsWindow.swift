import AppKit

/// 「自動で足した語」の一覧。1件ずつ外せる（外した組はもう登録し直さない）。
/// 中身は learned-terms.json の登録済みだけ。文章は持っていないので表示もしない。
final class LearnedTermsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: LearnedTermsStore
    private var rows: [LearnedPair] = []
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "")
    private let removeButton = NSButton(title: "選んだ語を外す", target: nil, action: nil)

    init(store: LearnedTermsStore = .shared) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "自動で足した語"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        for (id, title, width) in [("wrong", "聞き取り", 150.0), ("correct", "直した語", 150.0), ("count", "回数", 50.0),
                                   ("last", "最後に使った日", 100.0), ("screen", "画面", 40.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.bezelStyle = .rounded
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byWordWrapping
        summary.maximumNumberOfLines = 3
        summary.preferredMaxLayoutWidth = 520

        let content = NSView()
        for view in [summary, scroll, removeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            summary.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            summary.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            summary.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: removeButton.topAnchor, constant: -10),
            removeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            removeButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        window.contentView = content
        window.center()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func reload() {
        rows = store.registered
        table.reloadData()
        summary.stringValue = "AI補正が直した語を数えて、画面に出ていた語は1回、そうでない語は\(LearnedTerms.countToRegister)回で足しています。"
            + "いま\(rows.count)件（上限\(LearnedTerms.registeredLimit)件・\(LearnedTerms.expiryDays)日使わなければ外れます）。外した語はもう足しません。"
        updateButton()
    }

    private func updateButton() { removeButton.isEnabled = rows.indices.contains(table.selectedRow) }

    @objc private func removeSelected() {
        guard rows.indices.contains(table.selectedRow) else { NSSound.beep(); return }
        let pair = rows[table.selectedRow]
        store.remove(wrong: pair.wrong, correct: pair.correct)
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
        let pair = rows[row]
        let text: String
        switch id {
        case "wrong": text = pair.wrong
        case "correct": text = pair.correct
        case "count": text = "\(pair.count)"
        case "last": text = pair.lastUsed
        default: text = pair.seenOnScreen ? "○" : ""
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButton() }
}
