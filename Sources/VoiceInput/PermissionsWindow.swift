import AppKit

/// 何が足りないかを名指しで出し、その設定画面を直接開く。
final class PermissionsWindowController: NSWindowController {
    private var rows: [(Permission, NSTextField, NSButton)] = []
    private var timer: Timer?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "音声入力 — 権限の確認"
        window.center()
        self.init(window: window)
        buildContent()
    }

    private func buildContent() {
        guard let window = window else { return }
        let content = NSView(frame: window.contentLayoutRect)
        content.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "マイクとアクセシビリティを「システム設定 → プライバシーとセキュリティ」で許可してください。")
        header.font = .systemFont(ofSize: 12)
        header.textColor = .secondaryLabelColor
        stack.addArrangedSubview(header)

        for permission in Permission.allCases {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10

            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: 15)
            status.setContentHuggingPriority(.required, for: .horizontal)
            status.widthAnchor.constraint(equalToConstant: 22).isActive = true

            let label = NSTextField(labelWithString: "")
            label.allowsEditingTextAttributes = false
            label.font = .systemFont(ofSize: 13)
            label.widthAnchor.constraint(equalToConstant: 330).isActive = true
            label.maximumNumberOfLines = 2
            label.stringValue = "\(permission.title)  —  \(permission.reason)"

            let button = NSButton(title: "設定を開く", target: self, action: #selector(openSetting(_:)))
            button.bezelStyle = .rounded
            button.tag = Permission.allCases.firstIndex(of: permission)!

            row.addArrangedSubview(status)
            row.addArrangedSubview(label)
            if permission.showsSettingsButton {
                row.addArrangedSubview(button)
            }
            if permission == .accessibility {
                let reveal = NSButton(title: "アプリを表示", target: self, action: #selector(revealApp))
                reveal.bezelStyle = .rounded
                reveal.toolTip = "一覧に出てこないときは、ここで開いた Finder から VoiceInput.app を一覧へドラッグしてください"
                row.addArrangedSubview(reveal)
            }
            stack.addArrangedSubview(row)
            rows.append((permission, status, button))
        }

        let note = NSTextField(wrappingLabelWithString:
            "許可した直後は、いったんこのアプリを終了して起動し直してください。"
            + "macOS は起動時の許可状態を掴んだままにすることがあります。\n"
            + "アクセシビリティの一覧に VoiceInput が出てこないときは、「アプリを表示」で開いた Finder から"
            + "一覧へドラッグしてください。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.preferredMaxLayoutWidth = 460
        stack.addArrangedSubview(note)

        let refresh = NSButton(title: "再確認", target: self, action: #selector(refresh))
        refresh.bezelStyle = .rounded
        stack.addArrangedSubview(refresh)

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
        ])
        window.contentView = content
        refreshStatuses()
    }

    @objc private func openSetting(_ sender: NSButton) {
        Permissions.open(Permission.allCases[sender.tag])
    }

    @objc private func refresh() { refreshStatuses() }

    /// 一覧へドラッグしてもらうために、アプリ本体を Finder で開く。
    @objc private func revealApp() {
        guard let url = Bundle.main.bundleURL as URL? else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func refreshStatuses() {
        for (permission, status, button) in rows {
            let granted = permission.isGranted
            status.stringValue = granted ? "✅" : (permission.isRequired ? "❌" : "—")
            button.isHidden = granted || !permission.showsSettingsButton
        }
    }

    func show() {
        refreshStatuses()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshStatuses()
        }
    }

    override func close() {
        timer?.invalidate()
        timer = nil
        super.close()
    }
}
