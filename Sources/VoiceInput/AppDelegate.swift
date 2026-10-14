import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    enum State {
        case idle, recording, processing
        var label: String {
            switch self {
            case .idle: return "待機中"
            case .recording: return "録音中"
            case .processing: return "変換中"
            }
        }
    }

    private var statusItem: NSStatusItem!
    private let hotKey = HotKeyManager()
    private let recorder = Recorder()
    private let meeting = MeetingController()
    private var meetingStartPanel: NSPanel?
    private var meetWatchTimer: Timer?
    private var automaticMeetingCode: String?
    private var meetingContinuity = MeetingContinuity()
    private var suppressedMeetingCode: String?
    private var liveDictation: LiveDictation?
    private var processingAudioURL: URL?
    private let progressPanel = MenuProgress()
    private var pendingDraft: String?
    private var settings = Settings.load()
    private var permissionsWindow: PermissionsWindowController?

    private var state: State = .idle { didSet { updateStatusIcon() } }
    private var history: [String] = []          // 直近10件。メモリだけ。ディスクに残さない
    private var lastWarnings: [String] = []
    private var polishStatus = AnthropicAPI.hasKey ? "仕上げ: APIキーで Claude を使う" : "仕上げ: 次の変換時にMaxログインを確認"
    private var contextStatus = "画面参照: 次の録音開始時に取得"
    private var clientStatus = "顧客資料: フォルダ未選択"
    private var recordingPreparation: ReferencePreparation?
    private var recordingClient: ClientContext?
    private var recordingContext: ScreenContext?
    private var recordingScreenPreparation: ScreenPreparation?
    private var targetApp: NSRunningApplication?
    private var blinkTimer: Timer?
    private var blinkOn = false
    private var hotKeyRegistered = false
    private var lastError: String?
    /// メニューから開始したときの貼り付け先。ホットキー起動では使わない。
    private var pendingTargetOverride: NSRunningApplication?
    /// 権限画面は1起動につき1回だけ自動で出す。毎回出すと邪魔になる。
    private var permissionsShownOnce = false

    private let work = DispatchQueue(label: "com.ishot.voice-input.work", qos: .userInitiated)

    // MARK: - 起動

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Paths.bootstrap()
        Log.rotateIfNeeded()
        Log.write("起動 v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        // 起動時の権限を必ず残す。「許可したのに動かない」の切り分けはここから始まる。
        Log.write("権限 " + Permission.allCases
            .map { "\($0.title)=\($0.isGranted ? "○" : "×")" }.joined(separator: " "))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        progressPanel.onChange = { [weak self] display in
            guard let self, let button = self.statusItem.button, !self.meeting.blocksRecording else { return }
            if self.state == .idle && self.meeting.processingCount > 0 { self.updateStatusIcon(); return }
            button.image = self.symbol(display.symbol, display.tooltip)
            button.title = display.title
            button.toolTip = display.tooltip
        }
        meeting.onRecordingFailure = { [weak self] message in
            guard let self else { return }
            self.lastError = message
            self.suppressedMeetingCode = self.automaticMeetingCode
            self.automaticMeetingCode = nil
        }
        meeting.canStartBackground = { [weak self] in self?.state == .idle }
        meeting.onChange = { [weak self] in
            guard let self else { return }
            if !self.meeting.isBusy && self.meeting.status.hasPrefix("要確認:") {
                self.lastError = self.meeting.status
                Log.write(self.meeting.status)
            }
            self.updateStatusIcon()
        }
        meetWatchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkMeetBridge() }
        updateStatusIcon()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showJevSettings), name: Notification.Name("com.ishot.voice-input.show-jev"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receiveSharedScreen(_:)), name: Notification.Name("com.ishot.voice-input.shared-screen"), object: nil)
        MeetingTranscriptOutbox.shared.start()
        prepareSelectedDictionary()
        ResidentTranscriber.warm(modelPath: settings.resolvedModel, useMLX: settings.mlxForDictation)

        if CommandLine.arguments.contains("--app-capture-selftest") {
            meetWatchTimer?.invalidate()
            if CommandLine.arguments.contains("--silent-start-test") { settings.startSound = "" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.beginRecording()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    let recording = self.recorder.stop()
                    self.liveDictation?.cancel(); self.liveDictation = nil
                    self.state = .idle
                    print("GUI capture seconds=\(recording?.duration ?? 0)")
                    if let recording { try? FileManager.default.removeItem(at: recording.url) }
                    ResidentTranscriber.shutdown()
                    exit((recording?.duration ?? 0) > 1 ? 0 : 1)
                }
            }
            return
        }

        hotKeyRegistered = hotKey.register { [weak self] in self?.toggleRecording() }
        if !hotKeyRegistered {
            lastError = "⌥Space を登録できませんでした。他のアプリが同じキーを使っています。"
        }

        Permissions.requestMicrophone { granted in
            if !granted { Log.write("マイクが未許可") }
            let missing = Permissions.missingRequired
            if !missing.isEmpty {
                Log.write("権限が足りない: " + missing.map(\.title).joined(separator: "・"))
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard meeting.isBusy else { return .terminateNow }
        meeting.prepareForTermination { DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder.discard()
        liveDictation?.cancel()
        if !settings.keepAudioForDebug, let url = processingAudioURL { try? FileManager.default.removeItem(at: url) }
        ResidentTranscriber.shutdown()
        hotKey.unregister()
        Log.write("終了")
    }

    /// /System/Library/Sounds の音を鳴らす。名前が空なら何もしない。
    private let recordingCue = RecordingCue()
    private func play(_ name: String) { recordingCue.play(name) }

    // MARK: - 状態表示

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        if meeting.blocksRecording || (meeting.processingCount > 0 && state == .idle) {
            blinkTimer?.invalidate(); blinkTimer = nil
            button.image = symbol(meeting.state == .recording ? "record.circle.fill" : "hourglass", meeting.status)
            button.contentTintColor = meeting.state == .recording ? .systemRed : .systemOrange
            button.title = meeting.elapsed; button.toolTip = meeting.status
            return
        }
        switch state {
        case .idle:
            blinkTimer?.invalidate(); blinkTimer = nil
            button.image = symbol(lastError == nil ? "mic" : "exclamationmark.circle", lastError ?? "待機中")
            button.contentTintColor = lastError == nil ? nil : .systemOrange
            button.title = ""
            button.toolTip = lastError.map { "録音は停止しています。\n" + $0 } ?? "音声入力・待機中"
        case .recording:
            button.contentTintColor = .systemRed
            button.title = ""
            startBlinking()
        case .processing:
            blinkTimer?.invalidate(); blinkTimer = nil
            button.image = symbol("waveform", "変換中")
            button.contentTintColor = .systemOrange
            button.title = ""
        }
    }

    private func startBlinking() {
        blinkTimer?.invalidate()
        blinkOn = true
        statusItem.button?.image = symbol("record.circle.fill", "録音中")
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self, self.state == .recording else { return }
            self.blinkOn.toggle()
            self.statusItem.button?.image = self.symbol(
                self.blinkOn ? "record.circle.fill" : "record.circle", "録音中")
        }
    }

    private func symbol(_ name: String, _ description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = (name == "mic")
        return image
    }

    // MARK: - メニュー

    private var jevWindow: JevSettingsWindow?
    @objc private func showJevSettings() {
        jevWindow = JevSettingsWindow(settings: settings) { [weak self] in self?.settings = $0 }
        jevWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let jevItem = NSMenuItem(title: "Jevの設定…", action: #selector(showJevSettings), keyEquivalent: "")
        jevItem.target = self; menu.addItem(jevItem)

        addMeetingMenu(to: menu)

        let statusLine = NSMenuItem(title: "状態: \(state.label)", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        let contextLine = NSMenuItem(title: contextStatus, action: nil, keyEquivalent: "")
        contextLine.isEnabled = false
        menu.addItem(contextLine)
        let polishLine = NSMenuItem(title: polishStatus, action: nil, keyEquivalent: "")
        polishLine.isEnabled = false
        menu.addItem(polishLine)

        let hotKeyLine = NSMenuItem(
            title: hotKeyRegistered ? "⌥Space で開始／停止" : "⚠️ ⌥Space を登録できていません",
            action: nil, keyEquivalent: "")
        hotKeyLine.isEnabled = false
        menu.addItem(hotKeyLine)

        let missing = Permissions.missingRequired
        if !missing.isEmpty {
            let item = NSMenuItem(title: "⚠️ 権限が足りません: " + missing.map(\.title).joined(separator: "・"),
                                  action: #selector(showPermissions(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if let lastError {
            let item = NSMenuItem(title: "⚠️ \(lastError)", action: #selector(copyLastError), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if !lastWarnings.isEmpty {
            let item = NSMenuItem(title: "⚠️ 禁止語: " + lastWarnings.joined(separator: "・"),
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // ⌥Space が他アプリに取られている・届かないときの逃げ道
        let toggle = NSMenuItem(title: state == .recording ? "録音を止める" : "録音を始める",
                                action: #selector(toggleFromMenu), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = state != .processing
        menu.addItem(toggle)

        menu.addItem(.separator())

        let historyItem = NSMenuItem(title: "直近の変換結果", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if history.isEmpty {
            let empty = NSMenuItem(title: "（まだありません）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for (index, text) in history.enumerated() {
                let oneLine = text.replacingOccurrences(of: "\n", with: " ⏎ ")
                let title = oneLine.count > 48 ? String(oneLine.prefix(48)) + "…" : oneLine
                let item = NSMenuItem(title: title, action: #selector(copyHistory(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.toolTip = text
                submenu.addItem(item)
            }
        }
        historyItem.submenu = submenu
        menu.addItem(historyItem)

        menu.addItem(.separator())

        for (title, ai) in [("通常モード（AIで漢字を補正）", true), ("高速入力モード（Mac内ですぐ変換）", false)] {
            let mode = NSMenuItem(title: title, action: #selector(selectInputMode(_:)), keyEquivalent: "")
            mode.target = self; mode.tag = ai ? 1 : 0
            mode.state = settings.polishWithClaude == ai ? .on : .off
            mode.isEnabled = state == .idle
            menu.addItem(mode)
        }
        if pendingDraft != nil {
            let recover = NSMenuItem(title: "直前の文字起こし結果をコピー", action: #selector(copyPendingDraft), keyEquivalent: "")
            recover.target = self; menu.addItem(recover)
        }

        for (title, action, enabled) in [
            ("入力画面を参考にする（端末内）", #selector(toggleContext), settings.useScreenContext),
            ("画面の参考情報もClaudeに送る", #selector(toggleCloudContext), settings.shareScreenContextWithClaude)
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = enabled ? .on : .off
            item.isEnabled = state == .idle
            menu.addItem(item)
        }
        let preferences = NSMenuItem(title: "仕上げの文体を設定…", action: #selector(openSettings), keyEquivalent: "")
        preferences.target = self
        preferences.isEnabled = state == .idle
        menu.addItem(preferences)
        let apiKey = NSMenuItem(title: AnthropicAPI.hasKey ? "Claude APIキー: 設定済み（変更・削除…）" : "Claude APIキーを設定…", action: #selector(showAPIKeySettings), keyEquivalent: "")
        apiKey.target = self
        apiKey.isEnabled = state == .idle
        menu.addItem(apiKey)
        let clientLine = NSMenuItem(title: clientStatus, action: nil, keyEquivalent: "")
        clientLine.isEnabled = false
        menu.addItem(clientLine)
        let clientPath = NSMenuItem(title: settings.selectedClientFolder.isEmpty ? "顧客フォルダ: 未選択" : "顧客フォルダ: " + settings.selectedClientFolder, action: nil, keyEquivalent: "")
        clientPath.isEnabled = false
        menu.addItem(clientPath)
        for (title, action) in [("顧客資料フォルダを選ぶ…", #selector(selectClientFolder)), ("顧客フォルダの選択を解除", #selector(clearClientFolder)), ("人名の読みを登録…", #selector(registerClientName))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = state == .idle
            menu.addItem(item)
        }

        let permissions = NSMenuItem(title: "権限を確認…", action: #selector(showPermissions(_:)), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        let reveal = NSMenuItem(title: "アプリを Finder で表示", action: #selector(revealApp), keyEquivalent: "")
        reveal.target = self
        reveal.toolTip = "アクセシビリティの一覧に追加するとき、ここから Finder を開いてドラッグします"
        menu.addItem(reveal)

        let terms = NSMenuItem(title: "用語辞書を開く", action: #selector(openTerms), keyEquivalent: "")
        terms.target = self
        menu.addItem(terms)

        let log = NSMenuItem(title: "ログを開く", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// メニューから開始したときは、前面が自分になっている。
    /// 貼り付け先は「自分の1つ前に前面だったアプリ」を選ぶ。
    @objc private func toggleFromMenu() {
        if state == .idle {
            let others = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            pendingTargetOverride = others.first { $0.isActive } ?? NSWorkspace.shared.frontmostApplication
        }
        toggleRecording()
    }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        guard history.indices.contains(sender.tag) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(history[sender.tag], forType: .string)
    }

    @objc private func copyLastError() {
        guard let lastError else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lastError, forType: .string)
    }

    @objc private func selectInputMode(_ sender: NSMenuItem) {
        guard state == .idle else { return }
        settings.polishWithClaude = sender.tag == 1
        settings.save()
        polishStatus = settings.polishWithClaude ? "通常モード: AI補正が終わるまで待つ" : "高速入力モード: Mac内で変換"
    }

    @objc private func copyPendingDraft() {
        guard let text = pendingDraft else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func toggleContext() {
        settings.useScreenContext.toggle()
        settings.save()
    }

    @objc private func toggleCloudContext() {
        settings.shareScreenContextWithClaude.toggle()
        settings.save()
    }

    private func prepareSelectedDictionary() {
        let folder = settings.selectedClientFolder
        guard !folder.isEmpty else { return }
        clientStatus = "顧客辞書: 作成中"
        DispatchQueue.global(qos: .utility).async {
            let prepared = ClientDictionary.prepare(folder: folder)
            DispatchQueue.main.async {
                guard self.settings.selectedClientFolder == folder else { return }
                self.clientStatus = prepared.unavailable ? "顧客辞書: 作成できませんでした" : "顧客辞書: 準備済み" + (prepared.truncated ? "（資料の一部）" : "")
            }
        }
    }

    @objc private func selectClientFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.init(filenameExtension: "md")!, .init(filenameExtension: "markdown")!]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "選んだMarkdownまたはフォルダから会社名・人物名・住所などの辞書JSONを作ります。"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            settings.selectedClientFolder = url.standardizedFileURL.path
            settings.save()
            prepareSelectedDictionary()
        }
    }

    @objc private func clearClientFolder() {
        settings.selectedClientFolder = ""
        settings.save()
        recordingClient = nil
        clientStatus = "顧客資料: フォルダ未選択"
    }

    @objc private func registerClientName() {
        guard !settings.selectedClientFolder.isEmpty else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "この顧客の人名の読みを登録"
        alert.informativeText = "上: 読み（例 たかはしゆうすけ）／下: 資料内の正確な表記（例 髙橋祐介）。同じ読みの登録は上書きします。"
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 70))
        let reading = NSTextField(frame: NSRect(x: 0, y: 40, width: 420, height: 24))
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        view.addSubview(reading); view.addSubview(name)
        alert.accessoryView = view
        alert.addButton(withTitle: "登録"); alert.addButton(withTitle: "キャンセル")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pair = [reading.stringValue.trimmingCharacters(in: .whitespacesAndNewlines): name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)]
        let client = ClientContext.load(folderPath: settings.selectedClientFolder)
        guard !client.validatedAliases(pair).isEmpty else {
            let error = NSAlert(); error.messageText = "読みと、読み込める資料内にある正確な人名を入力してください。"; error.runModal(); return
        }
        settings.clientNameAliases[settings.selectedClientFolder, default: [:]].merge(pair) { _, new in new }
        settings.save()
    }

    /// API キーはキーチェーンにだけ保存する。設定ファイル・ログには書かない。
    @objc private func showAPIKeySettings() {
        let alert = NSAlert()
        alert.messageText = "Claude APIキー"
        alert.informativeText = "Anthropic Console（console.anthropic.com）で発行したキー（sk-ant- で始まる）を貼り付けてください。キーを入れると、通常モードと会議の議事録はこのキーで Claude を使います（使った分だけ Anthropic から請求されます）。キーを入れない場合は、Claude Code の Max プランのログインを使います。"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = AnthropicAPI.hasKey ? "保存済み（変えるときだけ貼り付け）" : "sk-ant-..."
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        if AnthropicAPI.hasKey { alert.addButton(withTitle: "キーを削除") }
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let key = field.stringValue
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do {
                try AnthropicKeychain.store(key)
                polishStatus = "仕上げ: APIキーで Claude を使う"
                Log.write("Claude APIキーを保存")
            } catch {
                let failed = NSAlert(); failed.messageText = error.localizedDescription; failed.runModal()
            }
        case .alertThirdButtonReturn:
            AnthropicKeychain.remove()
            polishStatus = "仕上げ: 次の変換時にMaxログインを確認"
            Log.write("Claude APIキーを削除")
        default: break
        }
    }

    @objc private func openSettings() {
        let alert = NSAlert()
        alert.messageText = "仕上げの文体"
        alert.informativeText = "例：チャットでは短く自然に。メールでは丁寧に。話した内容は追加しません。通常モードで Claude が仕上げるときに使います。"
        let field = NSTextField(wrappingLabelWithString: "")
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.drawsBackground = true
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 90)
        field.stringValue = settings.customPolishInstructions
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            settings.customPolishInstructions = String(field.stringValue.prefix(2000))
            settings.save()
        }
    }

    @objc private func showPermissions(_ sender: Any?) {
        if permissionsWindow == nil { permissionsWindow = PermissionsWindowController() }
        permissionsWindow?.show()
    }

    @objc private func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @objc private func openTerms() {
        Paths.bootstrap()
        NSWorkspace.shared.open(Paths.terms)
    }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: Paths.log.path) {
            try? "".write(to: Paths.log, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(Paths.log)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - 本体

    private func toggleRecording() {
        guard !meeting.blocksRecording else { return }
        switch state {
        case .idle: beginRecording()
        case .recording: endRecording()
        case .processing: Log.write("変換中のため無視した")
        }
    }

    private func beginRecording() {
        guard !meeting.blocksRecording else { return }
        recordingCue.cancelStart()
        settings = Settings.load()
        progressPanel.reset()
        recordingContext = nil
        recordingClient = nil
        lastError = nil
        lastWarnings = []

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            Permissions.requestMicrophone { granted in
                if granted { self.beginRecording() } else { self.showPermissions(nil) }
            }
            return
        }
        // 貼り付け先は「録音を始めたとき最前面だったアプリ」。途中で切り替えても戻せる。
        targetApp = pendingTargetOverride ?? NSWorkspace.shared.frontmostApplication
        pendingTargetOverride = nil
        recordingPreparation = ReferencePreparation(folder: settings.selectedClientFolder, cachedOnly: !settings.polishWithClaude)
        clientStatus = settings.selectedClientFolder.isEmpty ? "顧客資料: 未選択" : "顧客辞書: 準備中"
        if settings.polishWithClaude {
            DispatchQueue.global(qos: .userInitiated).async { Polisher.prepareAuthentication() }
        }
        recordingScreenPreparation = settings.useScreenContext ? ScreenPreparation(app: targetApp) : nil
        contextStatus = settings.useScreenContext ? "画面参照: 録音と並行して取得中" : "画面参照: オフ"
        Log.write("入力モード: \(settings.polishWithClaude ? "通常（AI校正あり）" : "高速（AI校正なし）") Jev=\(settings.jev.dictation)")
        let live = LiveDictation(settings: settings, preparation: recordingPreparation, context: recordingContext, screenPreparation: recordingScreenPreparation)
        liveDictation = live
        recorder.onSamples = { [weak live] samples in live?.append(samples) }
        recorder.onReady = { [weak self] in
            guard let self, self.state == .recording else { return }
            self.recordingCue.playStart(self.settings.startSound) { [weak self] in
                self?.state == .recording
            }
        }
        recorder.onFailure = { [weak self] message in
            guard let self, self.state == .recording else { return }
            self.recordingCue.cancelStart()
            if self.recorder.writtenFrames > 0 {
                Log.write(message + " 取得済み音声の変換へ進みます。")
                self.endRecording()
                return
            }
            self.recorder.discard()
            self.liveDictation?.cancel(); self.liveDictation = nil
            self.recorder.onSamples = nil
            self.recordingContext = nil
            self.lastError = message; self.state = .idle
            Log.write(message)
        }
        do {
            try recorder.start()
            state = .recording
            // 録音が始まったことを耳でも分かるようにする。切り忘れ防止のアイコン点滅と対にする。
            // The cue is emitted by onReady after the capture worker supplies audio.
        } catch {
            recordingContext = nil
            recordingClient = nil
            lastError = error.localizedDescription
            recorder.discard()
            liveDictation?.cancel(); liveDictation = nil; recorder.onSamples = nil
            Log.write("録音を開始できない: \(error.localizedDescription)")
            state = .idle
        }
    }

    private func endRecording() {
        recordingCue.cancelStart()
        guard let recording = recorder.stop() else { state = .idle; return }
        let live = liveDictation
        processingAudioURL = recording.url
        recorder.onSamples = nil
        state = .processing
        play(settings.stopSound)
        progressPanel.begin(destination: targetApp?.localizedName ?? "入力先")

        let settings = self.settings
        let target = targetApp
        let preparation = recordingPreparation
        recordingPreparation = nil
        recordingClient = nil
        let aliases = settings.clientNameAliases[settings.selectedClientFolder] ?? [:]
        let screenPreparation = recordingScreenPreparation
        recordingScreenPreparation = nil
        let initialContext = recordingContext
        recordingContext = nil
        work.async { [weak self] in
            guard let self else { return }
            let context = screenPreparation?.wait() ?? initialContext
            DispatchQueue.main.async {
                self.contextStatus = context.map { "画面参照: \($0.focusedText.count)文字（\(settings.shareScreenContextWithClaude ? "AI校正へ送信" : "端末内のみ")）" } ?? "画面参照: テキスト取得なし"
            }
            var completedSuccessfully = false
            defer {
                live?.cancel()
                DispatchQueue.main.async {
                    if let live, self.liveDictation === live { self.liveDictation = nil }
                    if self.processingAudioURL == recording.url { self.processingAudioURL = nil }
                }
                if completedSuccessfully && !settings.keepAudioForDebug {
                    try? FileManager.default.removeItem(at: recording.url)
                } else if !completedSuccessfully {
                    let recovery = Paths.root.appendingPathComponent("recovery", isDirectory: true)
                    do {
                        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        let destination = recovery.appendingPathComponent(recording.url.lastPathComponent)
                        try FileManager.default.moveItem(at: recording.url, to: destination)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                        Log.write("未完了の録音を復旧用に保存: " + destination.lastPathComponent)
                    } catch { Log.write("復旧用音声の移動に失敗: 元ファイルを保持") }
                }
            }

            if recording.tooShort {
                self.finish(nil, warning: "短すぎて拾えませんでした（\(String(format: "%.1f", recording.duration))秒）", target: target)
                return
            }
            if recording.looksSilent {
                self.finish(nil, warning: String(format: "音が入っていません（peak %.3f / rms %.4f）。入力デバイスと距離を確認してください。",
                                                 recording.peak, recording.rms), target: target)
                return
            }
            guard let whisper = settings.resolvedWhisper else {
                self.finish(nil, warning: Transcriber.TranscribeError.whisperMissing.localizedDescription, target: target)
                return
            }

            let client = preparation?.wait()
            if settings.polishWithClaude && !settings.selectedClientFolder.isEmpty && (client == nil || client!.unavailable || client!.referenceText.isEmpty) {
                self.finish(nil, warning: "顧客辞書を準備できませんでした。資料を確認してください。未補正文は貼り付けません。", target: target)
                return
            }
            DispatchQueue.main.async { self.clientStatus = client?.status ?? "顧客資料: 未選択" }
            let terms = TermDictionary.load()
            let transcriber = Transcriber(whisperPath: whisper,
                                          modelPath: settings.resolvedModel,
                                          language: settings.language,
                                          initialPrompt: client?.initialPrompt(dictionary: terms.initialPrompt, screen: context, aliases: aliases) ?? context?.initialPrompt(dictionary: terms.initialPrompt) ?? terms.initialPrompt,
                                          fastMode: !settings.polishWithClaude, useMLX: settings.mlxForDictation)
            let raw: String
            do {
                if let live {
                    do { raw = try live.finish() }
                    catch {
                        Log.write("録音中文字起こしを再確認: 全音声で再変換")
                        raw = try transcriber.transcribe(recording.url)
                    }
                } else { raw = try transcriber.transcribe(recording.url) }
            } catch {
                self.finish(nil, warning: error.localizedDescription, target: target)
                return
            }
            guard !raw.isEmpty else {
                self.finish(nil, warning: "文字が取れませんでした。", target: target)
                return
            }
            // 小さい音のときに whisper が出す決まり文句を、そのまま貼らない
            if Hallucination.isOnly(raw) {
                Log.write("決まり文句だけだったので捨てた: \(raw)")
                self.finish(nil, warning: "音声を拾えませんでした。もう少し近くで話してください。", target: target)
                return
            }

            let formatter = Formatter(terms: terms,
                                      forbiddenWords: StyleWords.load(from: settings.styleWordsPath),
                                      dropSelfCorrections: settings.dropSelfCorrections,
                                      spaceAroundLatin: settings.spaceAroundLatin,
                                      trimTrailingPeriod: settings.trimTrailingPeriod)
            var result = formatter.format(raw)
            let draft = result.text
            DispatchQueue.main.async { self.pendingDraft = draft }

            if settings.polishWithClaude {
                do {
                    DispatchQueue.main.async { self.progressPanel.update("AIで補正中", detail: "画面と顧客辞書を参照しています。") }
                    let progress: (Int, Int) -> Void = { done, total in
                        DispatchQueue.main.async { self.progressPanel.update("AIで補正中", detail: "補正済み \(done)／\(total)文。全文の完了を待っています。") }
                    }
                    let polished: String
                    if let live { polished = try live.polish(result.text, client: client, progress: progress) }
                    else {
                        polished = try SentencePolisher.polish(result.text, polisher: Polisher(model: settings.polishModel, effort: settings.polishEffort), context: settings.shareScreenContextWithClaude ? context : nil, client: client, aliases: aliases, instructions: settings.customPolishInstructions, jevSettings: settings.jev, progress: progress)
                    }
                    if !polished.isEmpty { result.text = polished }
                    let via = AnthropicAPI.hasKey ? "APIキー" : "Claude Code Max"
                    DispatchQueue.main.async { self.polishStatus = settings.polishModel.contains("haiku") ? "仕上げ: \(via)（Haiku／思考量指定なし）" : "仕上げ: \(via)（\(settings.polishModel) / \(settings.polishEffort)）" }
                } catch {
                    DispatchQueue.main.async {
                        self.polishStatus = "仕上げ: 失敗（原文をコピー済み）"
                        self.copyPendingDraft()
                    }
                    Log.write("AI補正に失敗したため貼り付けを中止: \(error.localizedDescription)")
                    self.finish(nil, warning: "AI補正に失敗しました。未補正の文字起こしをクリップボードに残しました。⌘Vで貼り付けできます。" + error.localizedDescription, target: target)
                    return
                }
            }

            Log.write("整形 \(raw.count)文字 → \(result.text.count)文字")
            // 話した内容はログに残さない。辞書に足す当て字を拾いたいときだけ、
            // settings.json の keepAudioForDebug を true にして中身も出す。
            if settings.keepAudioForDebug {
                Log.write("  生: \(raw)")
                Log.write("  後: \(result.text.replacingOccurrences(of: "\n", with: " / "))")
            }
            guard !Transcriber.hasRunawayRepetition(result.text) else {
                self.finish(nil, warning: "異常な反復を検出したため貼り付けを止めました。録音はMacの復旧用フォルダに保持します。", target: target)
                return
            }
            completedSuccessfully = true
            self.finish(result, warning: nil, target: target)
        }
    }

    private func finish(_ result: FormatResult?, warning: String?, target: NSRunningApplication?) {
        DispatchQueue.main.async {
            if let warning {
                self.state = .idle
                self.progressPanel.finish(error: warning)
                self.lastError = warning
                Log.write("中断: \(warning)")
                NSSound.beep()
                return
            }
            guard let result, !result.text.isEmpty else {
                self.state = .idle
                self.progressPanel.finish(error: "入力できる文章がありませんでした。")
                return
            }
            self.progressPanel.update("貼り付け中", detail: "元の入力先へ文章を入れています。")
            self.lastWarnings = result.styleWarnings
            self.history.insert(result.text, at: 0)
            if self.history.count > 10 { self.history.removeLast(self.history.count - 10) }
            self.pendingDraft = result.text
            Inserter.insert(result.text, into: target) { error in
                self.state = .idle
                self.progressPanel.finish(error: error?.localizedDescription)
                guard let error else { return }
                // クリップボードには載っているので、作業は止まらない
                self.lastError = error.localizedDescription
                Log.write("自動で貼れなかった: \(error.localizedDescription)")
                NSSound.beep()
                if !self.permissionsShownOnce {
                    self.permissionsShownOnce = true
                    }
            }
        }
    }
}

extension AppDelegate {
    private func addMeetingMenu(to menu: NSMenu) {
        let title = NSMenuItem(title: "会議: \(meeting.status)", action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title)
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.isEnabled = enabled; menu.addItem(item)
        }
        if meeting.state == .recording {
            add("会議録音を停止して議事録を作成", #selector(toggleMeeting))
        }
        add(MeetingGoogleDrive.shared.isAuthenticated ? "Google連携を変更…" : "Googleドライブを連携…", #selector(connectMeetingGoogle), enabled: !meeting.isBusy && state == .idle)
        add("議事録一覧を開く（Googleドライブ）", #selector(openMeetingList), enabled: MeetingGoogleDrive.shared.folderURL != nil)
        add("最新の議事録を開く", #selector(openMeetingDocument), enabled: meeting.latestURL != nil)
        add("未保存の会議を再処理・再送", #selector(retryMeeting), enabled: state == .idle && !meeting.isBusy && MeetingRecord.recent().contains { $0.status != "saved" })
        add("会議データをFinderで開く", #selector(openMeetingData))
        menu.addItem(.separator())
    }
    @objc private func connectMeetingGoogle() {
        guard state == .idle, !meeting.isBusy else { return }
        MeetingGoogleDrive.shared.connect { [weak self] result in
            switch result {
            case .success: self?.lastError = nil
            case .failure(let error): self?.lastError = error.localizedDescription
            }
            self?.updateStatusIcon()
        }
    }
    @objc private func openMeetingList() { if let url = MeetingGoogleDrive.shared.folderURL { NSWorkspace.shared.open(url) } }
    @objc private func openMeetingDocument() { if let url = meeting.latestURL { NSWorkspace.shared.open(url) } }
    @objc private func openMeetingData() {
        try? FileManager.default.createDirectory(at: MeetingRecord.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(MeetingRecord.root)
    }
    @objc private func retryMeeting() { guard state == .idle else { return }; meeting.retryLatest() }
    @objc private func receiveSharedScreen(_ notification: Notification) {
        guard let code = notification.userInfo?["code"] as? String, let text = notification.userInfo?["text"] as? String,
              text.count <= 6000, let at = notification.userInfo?["at"] as? Double,
              Date().timeIntervalSince1970 - at >= 0, Date().timeIntervalSince1970 - at < 15 else { return }
        DispatchQueue.main.async {
            guard self.automaticMeetingCode == code, self.meeting.state == .recording else { return }
            self.meeting.observeSharedScreen(text: text, at: at)
            Log.write("Meet共有資料: OCR \(text.count)文字（本文非保存）")
        }
    }
    private func checkMeetBridge() {
        struct Signal: Decodable { let joined: Bool; let code: String; let timestamp: Double; let title: String?; let selfName: String?; let observations: [MeetingPresence]? }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".voice-input/meet-bridge/state.json")
        let signal = (try? Data(contentsOf: path)).flatMap { try? JSONDecoder().decode(Signal.self, from: $0) }
        let active = signal.flatMap { value -> String? in
            let age = Date().timeIntervalSince1970 - value.timestamp
            return value.joined && age >= 0 && age < 12 && value.code.range(of: "^[a-z]{3}-[a-z]{4}-[a-z]{3}$", options: .regularExpression) != nil ? value.code : nil
        }
        if active != nil, active == automaticMeetingCode, let frames = signal?.observations { meeting.observeParticipants(frames) }
        if active != nil, active == automaticMeetingCode, let ownName = signal?.selfName, !ownName.isEmpty { meeting.setSelfDisplayName(ownName) }
        if let current = automaticMeetingCode,
           meetingContinuity.shouldStop(current: current, active: active, now: Date().timeIntervalSince1970) {
            if meeting.state == .recording { meeting.stop(); Log.write("Meet退出検知: 会議録音停止") }
            if meeting.state != .starting { automaticMeetingCode = nil }
            return
        }
        if active == nil { suppressedMeetingCode = nil }
        guard let code = active, code != suppressedMeetingCode, automaticMeetingCode == nil, state == .idle, !meeting.blocksRecording,
              let chrome = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.google.Chrome" }), MeetingRecognition.isAvailable else { return }
        automaticMeetingCode = code
        meetingContinuity.reset()
        lastError = nil
        Log.write("Meet参加検知: 会議録音開始")
        progressPanel.reset()
        meeting.begin(title: signal?.title ?? "", meetingCode: code, browserPID: chrome.processIdentifier, settings: Settings.load())
    }

    @objc private func toggleMeeting() {
        guard meeting.state == .recording else { return }
        suppressedMeetingCode = automaticMeetingCode
        automaticMeetingCode = nil
        meeting.stop()
    }
}
