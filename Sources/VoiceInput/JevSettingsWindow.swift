import AppKit

/// Menu-bar apps have no Edit menu to route Command-V to the field editor.
private final class JevKeyField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, let editor = currentEditor() {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": editor.paste(nil); return true
            case "a": editor.selectAll(nil); return true
            case "x": editor.cut(nil); return true
            case "c": editor.copy(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class JevSettingsWindow: NSWindowController {
    private let normal = NSButton(checkboxWithTitle: "音声入力にJevを使う（保存時に通常モードへ切替）", target: nil, action: nil)
    private let meeting = NSButton(checkboxWithTitle: "Meet議事録の校正にJevの候補を使う", target: nil, action: nil)
    private let consent = NSButton(checkboxWithTitle: "送信対象・保持条件を確認し、TypeSafeへの送信に同意する", target: nil, action: nil)
    private let key = JevKeyField()
    private let monthly = NSTextField(string: "10")
    private let perMeeting = NSTextField(string: "1")
    private let status = NSTextField(wrappingLabelWithString: "")
    private var settings: Settings
    private let changed: (Settings) -> Void
    init(settings: Settings, changed: @escaping (Settings) -> Void) {
        self.settings = settings; self.changed = changed
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 630), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Jevの設定"; window.isReleasedWhenClosed = false
        super.init(window: window)
        normal.state = settings.jev.dictation ? .on : .off
        meeting.state = settings.jev.meeting ? .on : .off
        consent.state = settings.jev.sharingAccepted ? .on : .off
        monthly.stringValue = String(settings.jev.monthlyUSD); perMeeting.stringValue = String(settings.jev.meetingUSD)
        key.placeholderString = "APIキー（空欄なら保存済みキーを維持）"
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -22), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22)])
        let info = NSTextField(wrappingLabelWithString: "Jev 1.13.0へ認識文・表記候補・必要な文脈を送ります。音声や画像は送りません。Claude Code Maxとは別料金です。\n公式は学習に使わないと説明していますが、保持ゼロではありません。通常契約の保持期間は目的・法令に応じた期間で、日数は明示されていません。\nJevの表記候補をClaudeが確認して文章に反映します。Jev単独での自動置換は行いません。高速モードは速度優先のため本文への反映は通常モードで行います。")
        for view in [info, normal, meeting, key, NSTextField(labelWithString: "月額上限 USD（最大10）"), monthly, NSTextField(labelWithString: "会議1件の上限 USD"), perMeeting, consent, status] { stack.addArrangedSubview(view) }
        for field in [key, monthly, perMeeting] { field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let pasteButton = NSButton(title: "APIキーを貼り付け", target: self, action: #selector(pasteKey))
        stack.addArrangedSubview(pasteButton)
        let buttons = NSStackView()
        for (title, action) in [("保存", #selector(save)), ("匿名テスト", #selector(test)), ("データ保持条件", #selector(legal)), ("キー削除", #selector(deleteKey))] {
            let button = NSButton(title: title, target: self, action: action); buttons.addArrangedSubview(button)
        }
        stack.addArrangedSubview(buttons)
        refresh()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    private func refresh() {
        let usage = JevBudget.shared.usage()
        status.stringValue = usage.map { String(format: "今月のAPI使用量 $%.5f／送信中・結果不明の予約 $%.5f", $0.confirmed, $0.reserved) } ?? "使用量を読めないため送信停止"
    }
    @objc private func save() {
        guard let month = Double(monthly.stringValue), month.isFinite, month > 0, month <= 10,
              let cap = Double(perMeeting.stringValue), cap.isFinite, cap > 0, cap <= month else {
            status.stringValue = "月額は0より大きく10以下、会議上限は月額以下で指定してください。"; return
        }
        do {
            if !key.stringValue.isEmpty { try JevKeychain.store(key.stringValue); key.stringValue = "" }
            if normal.state == .on || meeting.state == .on {
                guard consent.state == .on, JevKeychain.read() != nil else { status.stringValue = "有効化には送信同意とAPIキーが必要です。"; return }
            }
            settings.jev.dictation = normal.state == .on; settings.jev.meeting = meeting.state == .on
            settings.jev.sharingAccepted = consent.state == .on
            settings.jev.monthlyUSD = month; settings.jev.meetingUSD = cap
            settings.jev.shadow = false
            if settings.jev.dictation { settings.polishWithClaude = true }
            settings.save(); changed(settings); refresh()
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func pasteKey() {
        guard let value = NSPasteboard.general.string(forType: .string), !value.isEmpty else {
            status.stringValue = "APIキーをコピーしてから押してください。"; return
        }
        key.stringValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        status.stringValue = "キーを入力しました。「保存」でKeychainへ保存します。"
    }
    @objc private func legal() { NSWorkspace.shared.open(URL(string: "https://typesafe.ai/legal/data-processing")!) }
    @objc private func deleteKey() {
        JevKeychain.remove(); settings.jev.dictation = false; settings.jev.meeting = false
        normal.state = .off; meeting.state = .off; key.stringValue = ""
        settings.save(); changed(settings); status.stringValue = "キーを削除し、Jevを無効にしました。"
    }
    @objc private func test() {
        save()
        guard JevKeychain.read() != nil else { return }
        var config = settings.jev
        // Explicit button sends this fixed synthetic sentence only, never screen/client data.
        config.sharingAccepted = true; config.dictation = true
        status.stringValue = "架空の短文で接続を確認中…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let reply = try JevClient().choose(state: ["original": "広告の製作費を確認します。", "context": "紹介動画を作ります。"],
                    questions: ["spelling": ["type": "choice", "instructions": "文脈に合う表記を選ぶ。", "criteria": ["creative": "制作", "keep": "製作", "unknown": "判断不能"]]],
                    session: "synthetic-" + UUID().uuidString, meeting: false, settings: config, cancelled: { false })
                DispatchQueue.main.async { self.refresh(); self.status.stringValue += "\n接続成功: \(reply.model)／\(reply.usage.input_tokens)入力トークン" }
            } catch { DispatchQueue.main.async { self.status.stringValue = "接続未完了: " + error.localizedDescription } }
        }
    }
}
