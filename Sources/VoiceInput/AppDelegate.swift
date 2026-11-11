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
    private let historyShortcut = HistoryShortcut()
    private var historyPasteTarget: NSRunningApplication?
    private var historyPopupOpen = false
    private let recorder = Recorder()
    private let meeting = MeetingController()
    private var meetingStartPanel: NSPanel?
    private var meetWatchTimer: Timer?
    private var automaticMeetingCode: String?
    private var meetingContinuity = MeetingContinuity()
    private var suppressedMeetingCode: String?
    private var liveDictation: LiveDictation?
    private var dictationQueue = DictationQueue()
    private let progressPanel = MenuProgress()
    private var pendingDraft: String?
    /// AI 補正に失敗して未解決の文章。ディスクにも同じものを置き、再起動しても扱える。
    private struct FailedPolish {
        let id: String
        let createdAt: Date
        let result: FormatResult
        /// 再起動をまたいだものは nil。やり直すときに今の設定で作る。
        let job: PolishJob?
        let target: NSRunningApplication?
        let targetBundleID: String?
        let recordingName: String?
        let keepAudio: Bool
        let clientFolder: String

        init(id: String = UUID().uuidString, createdAt: Date = Date(), result: FormatResult, job: PolishJob, target: NSRunningApplication?,
             recordingName: String?, keepAudio: Bool, clientFolder: String) {
            self.id = id; self.createdAt = createdAt; self.result = result; self.job = job; self.target = target
            targetBundleID = target?.bundleIdentifier
            self.recordingName = recordingName; self.keepAudio = keepAudio; self.clientFolder = clientFolder
        }

        init(restoring item: PendingPolish) {
            id = item.id; createdAt = item.createdAt
            result = FormatResult(text: item.text, styleWarnings: item.styleWarnings)
            job = nil
            target = item.targetBundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            targetBundleID = item.targetBundleID
            recordingName = item.recordingName; keepAudio = item.keepAudio; clientFolder = item.clientFolder
        }

        var pending: PendingPolish {
            PendingPolish(id: id, createdAt: createdAt, text: result.text, styleWarnings: result.styleWarnings,
                          targetBundleID: targetBundleID, recordingName: recordingName, keepAudio: keepAudio, clientFolder: clientFolder)
        }

        func resolvedJob() -> PolishJob { job ?? pending.restoredJob(settings: Settings.load()) }
    }
    /// 新しいものが先頭。主スレッドだけで触る。
    private var failedPolishes: [FailedPolish] = []
    private var failedPolish: FailedPolish? { failedPolishes.first }
    private var recoveryFolder = Paths.root.appendingPathComponent("recovery", isDirectory: true)
    private lazy var pendingStore = PendingPolishStore(folder: recoveryFolder)
    private lazy var linkMonitor = AILinkMonitor(activeProvider: { [weak self] in
        guard let self, self.settings.polishWithClaude else { return nil }
        return self.settings.aiProvider
    })
    /// 録音中にログインが済んだら、録音が終わってから文章の補正を勧める。
    private var offerPendingWhenIdle = false
    private var linkNoticeShown = false
    private var loginPanelOpen = false
    /// 失敗中のメニューの確認起動だけ true。
    private var ignoreRecoveryResolution = false
    /// 自己テストだけ true。
    private var avoidKeychainForCheck = false
    private let aiPanel = AIStatusPanel()
    private var settings = Settings.load()
    private var permissionsWindow: PermissionsWindowController?

    private var state: State = .idle {
        didSet {
            updateStatusIcon()
            if state == .idle, offerPendingWhenIdle { offerPendingAfterLogin() }
        }
    }
    private var history: [String] = []          // 直近5件。メモリだけ。ディスクに残さない
    private var lastWarnings: [String] = []
    private lazy var polishStatus = Self.readyStatus(for: settings.aiProvider)
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
        // 確認起動はターミナルの許可で動くので、常駐の権限の記録を上書きしない。
        let menuPreview = CommandLine.arguments.first { $0.hasPrefix("--menu-preview-") }
        if menuPreview == nil {
            Log.write("権限 " + Permission.allCases
                .map { "\($0.title)=\($0.isGranted ? "○" : "×")" }.joined(separator: " "))
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        progressPanel.onChange = { [weak self] display in
            guard let self, let button = self.statusItem.button, !self.meeting.blocksRecording, self.state != .recording else { return }
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
        meeting.canStartBackground = { [weak self] in self?.state != .recording }
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
        if let menuPreview { startMenuPreview(menuPreview); return }
        if recoveryResolvedThrough == nil { markRecordingsResolved(through: Date()) }
        restorePendingPolishes()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showJevSettings), name: Notification.Name("com.ishot.voice-input.show-jev"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receiveSharedScreen(_:)), name: Notification.Name("com.ishot.voice-input.shared-screen"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(diagnoseScreenContext), name: Notification.Name("com.ishot.voice-input.context-diagnostic"), object: nil)
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

        historyShortcut.onOpen = { [weak self] point, target in
            self?.showHistoryPopup(at: point, target: target)
        }
        historyShortcut.start()
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
        linkMonitor.onChange = { [weak self] old, new in self?.linkStatusChanged(from: old, to: new) }
        linkMonitor.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard meeting.isBusy else { return .terminateNow }
        meeting.prepareForTermination { DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder.discard()
        liveDictation?.cancel()
        // 未完了の録音は終了時に削除しない。変換完了時だけ片付ける。
        ResidentTranscriber.shutdown()
        hotKey.unregister()
        historyShortcut.stop()
        Log.write("終了")
    }

    /// /System/Library/Sounds の音を鳴らす。名前が空なら何もしない。
    private let recordingCue = RecordingCue()
    private func play(_ name: String) { recordingCue.play(name) }

    // MARK: - 状態表示

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
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
            button.title = ""
            if linkFix != nil {
                button.image = AILinkIcon.image()
                button.contentTintColor = nil
                button.toolTip = AILinkIcon.description + "。クリックしてログインしてください。"
                return
            }
            let warning = lastError ?? (settings.polishWithClaude ? linkMonitor.status.blockedMessage : nil)
            button.image = symbol(warning == nil ? "mic" : "exclamationmark.circle", warning ?? "待機中")
            button.contentTintColor = warning == nil ? nil : .systemOrange
            button.toolTip = warning.map { "録音は停止しています。\n" + $0 } ?? "音声入力・待機中"
        case .recording:
            button.contentTintColor = .systemRed
            button.title = linkFix == nil ? "" : "!"
            startBlinking()
        case .processing:
            blinkTimer?.invalidate(); blinkTimer = nil
            button.image = symbol("waveform", "変換中")
            button.contentTintColor = .systemOrange
            button.title = linkFix == nil ? "" : "!"
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

    private var preferencesWindow: SettingsWindowController?
    @objc private func showPreferences() {
        if preferencesWindow == nil {
            preferencesWindow = SettingsWindowController(snapshot: { [unowned self] in self.settingsSnapshot() },
                                                         perform: { [unowned self] in self.performSettings($0) })
        }
        preferencesWindow?.show()
    }

    private func settingsSnapshot() -> SettingsSnapshot {
        SettingsSnapshot(
            idle: state == .idle,
            useScreenContext: settings.useScreenContext,
            shareScreenContext: settings.shareScreenContextWithClaude,
            contextStatus: contextStatus,
            hasClientFolder: !settings.selectedClientFolder.isEmpty,
            provider: settings.aiProvider,
            providerTitles: AIProvider.allCases.map { $0.menuTitle + (Polisher.missingRequirement($0) == nil ? "" : "（" + Self.shortMissing($0) + "）") },
            aiStatus: polishStatus.replacingOccurrences(of: "仕上げ: ", with: ""),
            claudeKeyTitle: AnthropicAPI.hasKey ? "Claude APIキー: 設定済み…" : "Claude APIキーを設定…",
            openAIKeyTitle: OpenAIAPI.hasKey ? "OpenAI APIキー: 設定済み…" : "OpenAI APIキーを設定…",
            clientFolder: settings.selectedClientFolder.isEmpty ? "未選択" : settings.selectedClientFolder,
            clientStatus: clientStatus,
            meetingStatus: meeting.status,
            googleTitle: MeetingGoogleDrive.shared.isAuthenticated ? "Google連携を変更…" : "Googleドライブを連携…",
            googleEnabled: !meeting.isBusy && state == .idle)
    }

    private func performSettings(_ command: SettingsCommand) {
        switch command {
        case .toggleScreenContext: toggleContext()
        case .toggleCloudContext: toggleCloudContext()
        case .editStyle: openSettings()
        case .registerName: registerClientName()
        case .openTerms: openTerms()
        case .showPermissions: showPermissions(nil)
        case .revealApp: revealApp()
        case .openLog: openLog()
        case .selectProvider(let provider): applyAIProvider(provider)
        case .reconnectAI: reconnectAI()
        case .setClaudeKey: showAPIKeySettings()
        case .setOpenAIKey: showOpenAIKeySettings()
        case .showJev: showJevSettings()
        case .chooseClientFolder: selectClientFolder()
        case .clearClientFolder: clearClientFolder()
        case .connectGoogle: connectMeetingGoogle()
        case .openMeetingData: openMeetingData()
        }
    }

    private var jevWindow: JevSettingsWindow?
    @objc private func showJevSettings() {
        jevWindow = JevSettingsWindow(settings: settings) { [weak self] in self?.settings = $0 }
        jevWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        // 知らせる必要があるときだけ、最上部に出す
        var hasContext = false
        if let fix = linkFix {
            var enabled = state == .idle
            if case .login = fix { enabled = true }
            let login = plainItem("AIにログイン…", #selector(loginToAI), enabled: enabled)
            login.toolTip = Self.linkDescription(fix)
            menu.addItem(login)
            hasContext = true
        }
        if let line = headline {
            let item = plainItem(line.title, line.action, enabled: line.action != nil)
            item.toolTip = line.detail
            menu.addItem(item)
            hasContext = true
        }
        if meeting.state == .recording {
            menu.addItem(plainItem("会議録音を停止して議事録を作成", #selector(toggleMeeting)))
            hasContext = true
        }
        hasContext = addRecoveryMenu(to: menu) || hasContext
        if hasContext { menu.addItem(.separator()) }

        // ⌥Space が他アプリに取られている・届かないときの逃げ道
        let toggle = plainItem(state == .recording ? "録音を止める" : "録音を始める", #selector(toggleFromMenu), enabled: !meeting.blocksRecording)
        if hotKeyRegistered {
            toggle.keyEquivalent = " "
            toggle.keyEquivalentModifierMask = [.option]
        }
        menu.addItem(toggle)
        menu.addItem(historyMenuItem())

        menu.addItem(.separator())
        for (title, ai, detail) in [("通常モード", true, "AIで漢字を補正します"), ("高速入力モード", false, "Mac内ですぐ変換します")] {
            let mode = plainItem(title, #selector(selectInputMode(_:)), enabled: state == .idle)
            mode.tag = ai ? 1 : 0
            mode.state = settings.polishWithClaude == ai ? .on : .off
            mode.toolTip = detail
            menu.addItem(mode)
        }

        menu.addItem(.separator())
        menu.addItem(meetingMenuItem())

        menu.addItem(.separator())
        let preferences = plainItem("設定…", #selector(showPreferences))
        preferences.keyEquivalent = ","
        menu.addItem(preferences)
        let quit = plainItem("音声入力を終了", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func plainItem(_ title: String, _ action: Selector?, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    /// 最上部に出す1行。普段（待機中で問題なし）は nil。
    private var headline: (title: String, action: Selector?, detail: String?)? {
        if meeting.blocksRecording { return (Self.shortLine(meeting.status), nil, meeting.status) }
        switch state {
        case .recording: return ("録音中", nil, nil)
        case .processing: return ("変換中", nil, nil)
        case .idle: break
        }
        if meeting.processingCount > 0 { return (Self.shortLine(meeting.status), nil, meeting.status) }
        if settings.polishWithClaude, let blocked = linkMonitor.status.blockedMessage { return ("⚠️ " + Self.shortLine(blocked), nil, blocked) }
        if let lastError { return ("⚠️ " + Self.shortLine(lastError), #selector(copyLastError), lastError + "\n（クリックでコピー）") }
        let missing = Permissions.missingRequired
        if !missing.isEmpty { return ("⚠️ 権限が足りません: " + missing.map(\.title).joined(separator: "・"), #selector(showPermissions(_:)), nil) }
        if !hotKeyRegistered { return ("⚠️ ⌥Space を登録できていません", nil, nil) }
        if settings.polishWithClaude, let requirement = Polisher.missingRequirement(settings.aiProvider) {
            let text = requirement.errorDescription ?? ""
            return ("⚠️ " + Self.shortLine(text), nil, text)
        }
        if !lastWarnings.isEmpty { return ("⚠️ 禁止語: " + lastWarnings.joined(separator: "・"), nil, nil) }
        return nil
    }

    /// 長い知らせの最初の1文だけをメニューに出す。全文はツールチップとコピーで見られる。
    private static func shortLine(_ text: String) -> String {
        let first = text.components(separatedBy: "。").first ?? text
        return first.count > 34 ? String(first.prefix(34)) + "…" : first
    }

    private func historyMenuItem() -> NSMenuItem {
        let historyItem = NSMenuItem(title: "履歴", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        // 変換の途中など、履歴の先頭にまだ入っていない文字起こしだけ別に出す
        if pendingDraft != nil, pendingDraft != history.first {
            submenu.addItem(plainItem("直前の文字起こし結果をコピー", #selector(copyPendingDraft)))
            submenu.addItem(.separator())
        }
        if history.isEmpty {
            submenu.addItem(plainItem("（まだありません）", nil, enabled: false))
        } else {
            for (index, text) in history.enumerated() {
                let oneLine = text.replacingOccurrences(of: "\n", with: " ⏎ ")
                let item = plainItem(oneLine.count > 48 ? String(oneLine.prefix(48)) + "…" : oneLine, #selector(copyHistory(_:)))
                item.tag = index
                item.representedObject = text
                item.toolTip = text
                submenu.addItem(item)
            }
        }
        historyItem.submenu = submenu
        return historyItem
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

    private func showHistoryPopup(at point: NSPoint, target: NSRunningApplication?) {
        guard !historyPopupOpen else { return }
        historyPopupOpen = true
        historyPasteTarget = target
        defer { historyPopupOpen = false }
        let menu = NSMenu(title: "音声入力の履歴")
        let heading = NSMenuItem(title: "音声入力の履歴 · 選んで貼り付け", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        if history.isEmpty {
            let empty = NSMenuItem(title: "まだ履歴がありません", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for text in history.prefix(5) {
            let line = text.replacingOccurrences(of: "\n", with: " ⏎ ")
            let item = NSMenuItem(title: String(line.prefix(60)) + (line.count > 60 ? "…" : ""),
                                  action: #selector(pasteHistory(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = text
            item.toolTip = text
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    @objc private func pasteHistory(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let target = historyPasteTarget
        // Let menu tracking finish before restoring the input application's focus.
        DispatchQueue.main.async {
            Inserter.insert(text, into: target) { [weak self] error in
                if let error { self?.lastError = error.localizedDescription }
                Log.write(error == nil ? "履歴から貼り付けを実行" : "履歴はクリップボードへ保存（自動貼り付け不可）")
            }
        }
    }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
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
        linkMonitor.checkNow()
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
                polishStatus = Self.readyStatus(for: settings.aiProvider)
                linkMonitor.noteKeyChanged()
                Log.write("Claude APIキーを保存")
            } catch {
                let failed = NSAlert(); failed.messageText = error.localizedDescription; failed.runModal()
            }
        case .alertThirdButtonReturn:
            AnthropicKeychain.remove()
            polishStatus = Self.readyStatus(for: settings.aiProvider)
            linkMonitor.noteKeyChanged()
            Log.write("Claude APIキーを削除")
        default: break
        }
    }

    /// 今の道で、次の変換で何を使うか（足りないものがあればそれ）を1行で出す。
    static func readyStatus(for provider: AIProvider) -> String {
        if let missing = Polisher.missingRequirement(provider) { return "仕上げ: ⚠️ \(provider.menuTitle) は " + shortMissing(provider, missing) }
        switch provider {
        case .claude: return AnthropicAPI.hasKey ? "仕上げ: APIキーで Claude を使う" : "仕上げ: 次の変換時にMaxログインを確認"
        case .openAIAPI: return "仕上げ: OpenAI の APIキーを使う"
        case .codexCLI: return "仕上げ: 次の変換時に Codex の ChatGPT ログインを確認"
        }
    }

    static func shortMissing(_ provider: AIProvider, _ missing: Polisher.PolishError? = nil) -> String {
        switch missing ?? Polisher.missingRequirement(provider) {
        case .some(.cliMissing): return "APIキーも Claude Code も無し"
        case .some(.openAIKeyMissing): return "APIキー未設定"
        case .some(.codexMissing): return "codex 未インストール"
        default: return "準備できていません"
        }
    }

    /// 選んだものだけを使う。使えないときは別の会社の AI に切り替えず、足りないものを警告で出す。
    private func applyAIProvider(_ provider: AIProvider) {
        guard state == .idle, provider != settings.aiProvider else { return }
        settings.aiProvider = provider
        settings.save()
        Log.write("AI の仕上げに使うもの: \(provider.rawValue)")
        polishStatus = Self.readyStatus(for: provider)
        linkMonitor.checkNow()
        if let missing = Polisher.missingRequirement(provider) {
            let alert = NSAlert()
            alert.messageText = "\(provider.menuTitle) はまだ使えません"
            alert.informativeText = (missing.errorDescription ?? "") + "\n選んだままにしています。準備ができるまで、通常モードの変換は AI 補正をせずに止まります（原文はクリップボードに残します）。"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        guard provider == .codexCLI else { return }
        polishStatus = "仕上げ: Codex の ChatGPT ログインを確認中"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Polisher.ensureSubscription(.codexCLI) }
            DispatchQueue.main.async {
                guard self.settings.aiProvider == .codexCLI else { return }
                switch result {
                case .success: self.polishStatus = "仕上げ: Codex CLI（ChatGPTログイン確認済み）"
                case .failure(let error):
                    self.polishStatus = "仕上げ: ⚠️ Codex CLI のログインを確認できません"
                    let alert = NSAlert()
                    alert.messageText = "Codex CLI を使えません"
                    alert.informativeText = error.localizedDescription
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }
    }

    /// OpenAI の API キーもキーチェーンにだけ保存する（Claude のキーとは別の場所）。設定ファイル・ログには書かない。
    @objc private func showOpenAIKeySettings() {
        let alert = NSAlert()
        alert.messageText = "OpenAI APIキー"
        alert.informativeText = "OpenAI の管理画面（platform.openai.com の API keys）で発行したキー（sk- で始まる）を貼り付けてください。「AI の仕上げに使うもの」で「OpenAI（APIキー）」を選んだときだけ使います（使った分だけ OpenAI から請求されます）。ChatGPT のプランで使うときはキーは不要で、「OpenAI（Codex CLI・ChatGPTログイン）」を選びます。"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = OpenAIAPI.hasKey ? "保存済み（変えるときだけ貼り付け）" : "sk-..."
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        if OpenAIAPI.hasKey { alert.addButton(withTitle: "キーを削除") }
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let key = field.stringValue
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do {
                try OpenAIKeychain.store(key)
                polishStatus = Self.readyStatus(for: settings.aiProvider)
                linkMonitor.noteKeyChanged()
                Log.write("OpenAI APIキーを保存")
            } catch {
                let failed = NSAlert(); failed.messageText = error.localizedDescription; failed.runModal()
            }
        case .alertThirdButtonReturn:
            OpenAIKeychain.remove()
            polishStatus = Self.readyStatus(for: settings.aiProvider)
            linkMonitor.noteKeyChanged()
            Log.write("OpenAI APIキーを削除")
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
        case .processing: beginRecording()
        }
    }

    private func beginRecording() {
        guard !meeting.blocksRecording else { return }
        recordingCue.cancelStart()
        settings = Settings.load()
        progressPanel.reset()
        aiPanel.close()
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
        dictationQueue.beginRecording()
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
            self.lastError = message; self.state = .idle; self.restoreDictationState()
            Log.write(message)
        }
        do {
            try recorder.start()
            state = .recording
            linkMonitor.clearPolishBlock()
            linkNoticeShown = false
            if linkFix != nil { showLinkNotice() }
            if settings.polishWithClaude { linkMonitor.checkIfStale(olderThan: 10) }
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
            restoreDictationState()
        }
    }

    private func restoreDictationState() {
        guard state != .recording else { return }
        state = dictationQueue.pendingCount > 0 ? .processing : .idle
        if dictationQueue.pendingCount > 0 {
            progressPanel.begin(destination: "履歴へ保存（残り\(dictationQueue.pendingCount)件）")
        }
    }

    private func endRecording() {
        recordingCue.cancelStart()
        guard let recording = recorder.stop() else { state = .idle; restoreDictationState(); return }
        let live = liveDictation
        liveDictation = nil
        let job = dictationQueue.enqueue()
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
            var savedForRecovery = false
            /// 無音・短すぎ・文字が取れない録音。やり直しの候補に出さない（ファイルは残す）。
            var notWorthRetrying = false
            func saveForRecovery() {
                guard !savedForRecovery else { return }
                savedForRecovery = true
                let recovery = Paths.root.appendingPathComponent("recovery", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let destination = recovery.appendingPathComponent(recording.url.lastPathComponent)
                    try FileManager.default.moveItem(at: recording.url, to: destination)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                    Log.write("未完了の録音を復旧用に保存: " + destination.lastPathComponent)
                } catch { Log.write("復旧用音声の移動に失敗: 元ファイルを保持") }
            }
            defer {
                live?.cancel()
                DispatchQueue.main.async {
                    if let live, self.liveDictation === live { self.liveDictation = nil }

                }
                if completedSuccessfully && !settings.keepAudioForDebug {
                    try? FileManager.default.removeItem(at: recording.url)
                } else if !completedSuccessfully {
                    saveForRecovery()
                    if notWorthRetrying { self.markRecordingHandled(recording.url.lastPathComponent) }
                }
            }

            if recording.tooShort {
                notWorthRetrying = true
                self.finish(nil, warning: "短すぎて拾えませんでした（\(String(format: "%.1f", recording.duration))秒）", target: target, job: job)
                return
            }
            if recording.looksSilent {
                notWorthRetrying = true
                self.finish(nil, warning: String(format: "音が入っていません（peak %.3f / rms %.4f）。入力デバイスと距離を確認してください。",
                                                 recording.peak, recording.rms), target: target, job: job)
                return
            }
            guard let whisper = settings.resolvedWhisper else {
                self.finish(nil, warning: Transcriber.TranscribeError.whisperMissing.localizedDescription, target: target, job: job)
                return
            }

            let client = preparation?.wait()
            if settings.polishWithClaude && !settings.selectedClientFolder.isEmpty && (client == nil || client!.unavailable || client!.referenceText.isEmpty) {
                self.finish(nil, warning: "顧客辞書を準備できませんでした。資料を確認してください。未補正文は貼り付けません。", target: target, job: job)
                return
            }
            DispatchQueue.main.async { self.clientStatus = client?.status ?? "顧客資料: 未選択" }
            let terms = TermDictionary.load()
            let transcriber = Transcriber(whisperPath: whisper,
                                          modelPath: settings.resolvedModel,
                                          language: settings.language,
                                          initialPrompt: client?.initialPrompt(dictionary: terms.initialPrompt, screen: context, aliases: aliases) ?? context?.initialPrompt(dictionary: terms.initialPrompt) ?? terms.initialPrompt,
                                          fastMode: !settings.polishWithClaude, useMLX: settings.mlxForDictation)
            let whisperText: String
            do {
                if let live {
                    do { whisperText = try live.finish() }
                    catch {
                        Log.write("録音中文字起こしを再確認: 全音声で再変換")
                        whisperText = try transcriber.transcribe(recording.url)
                    }
                } else { whisperText = try transcriber.transcribe(recording.url) }
            } catch {
                self.finish(nil, warning: error.localizedDescription, target: target, job: job)
                return
            }
            guard !whisperText.isEmpty else {
                notWorthRetrying = true
                self.finish(nil, warning: "文字が取れませんでした。", target: target, job: job)
                return
            }
            // プロンプトのラベル語の漏れと、先頭・末尾に付いた決まり文句を外す
            let raw = Hallucination.clean(whisperText)
            if raw != whisperText.trimmingCharacters(in: .whitespacesAndNewlines) {
                Log.write("決まり文句・プロンプトの漏れを外した（\(whisperText.count)字→\(raw.count)字）")
            }
            // 小さい音のときに whisper が出す決まり文句を、そのまま貼らない
            if raw.isEmpty || Hallucination.isOnly(raw) {
                Log.write("決まり文句だけだったので捨てた: \(whisperText)")
                notWorthRetrying = true
                self.finish(nil, warning: "音声を拾えませんでした。もう少し近くで話してください。", target: target, job: job)
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
            let polishJob = PolishJob(text: draft, model: settings.polishModel, effort: settings.polishEffort,
                                      context: settings.shareScreenContextWithClaude ? context : nil, client: client, aliases: aliases,
                                      instructions: settings.customPolishInstructions, jevSettings: settings.jev)

            if settings.polishWithClaude {
                do {
                    DispatchQueue.main.async { self.progressPanel.update("AIで補正中", detail: "画面と顧客辞書を参照しています。") }
                    let progress: (Int, Int) -> Void = { done, total in
                        DispatchQueue.main.async { self.progressPanel.update("AIで補正中", detail: "補正済み \(done)／\(total)文。全文の完了を待っています。") }
                    }
                    let status: (String) -> Void = { message in
                        DispatchQueue.main.async { self.progressPanel.update(message, detail: "認証を確かめ直して、失敗した文だけ再試行しています。") }
                    }
                    let polished: String
                    if let live { polished = try live.polish(result.text, client: client, status: status, progress: progress) }
                    else {
                        polished = try polishJob.run(status: status, progress: progress)
                    }
                    if !polished.isEmpty { result.text = polished }
                    let via = settings.aiProvider.shortName
                    let detail: String
                    switch settings.aiProvider {
                    case .claude: detail = settings.polishModel.contains("haiku") ? "Haiku／思考量指定なし" : "\(settings.polishModel) / \(settings.polishEffort)"
                    case .openAIAPI, .codexCLI: detail = "\(settings.openAIModel) / \(settings.openAIEffort)"
                    }
                    DispatchQueue.main.async { self.polishStatus = "仕上げ: \(via)（\(detail)）" }
                } catch {
                    saveForRecovery()   // 失敗の窓に「前回の録音」を正しく出すため、窓より先に移す
                    self.reportPolishFailure(error, failed: FailedPolish(result: result, job: polishJob, target: target,
                                                                         recordingName: recording.url.lastPathComponent, keepAudio: settings.keepAudioForDebug,
                                                                         clientFolder: settings.selectedClientFolder), job: job)
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
                self.finish(nil, warning: "異常な反復を検出したため貼り付けを止めました。録音はMacの復旧用フォルダに保持します。", target: target, job: job)
                return
            }
            completedSuccessfully = true
            self.noteDictationSucceeded(usedAI: settings.polishWithClaude, provider: settings.aiProvider)
            self.finish(result, warning: nil, target: target, job: job)
        }
    }

    private func rememberTranscript(_ text: String) {
        if history.first == text { return }
        history.insert(text, at: 0)
        if history.count > 5 { history.removeLast(history.count - 5) }
    }

    /// requireFrontmost: 元のアプリが前面に無ければ、前面を奪わずクリップボードへ入れる（やり直しのとき）。
    /// 文章を渡せたら true（貼り付けか、クリップボードと履歴への保存）。
    @discardableResult
    private func finish(_ result: FormatResult?, warning: String?, target: NSRunningApplication?, job: Int, requireFrontmost: Bool = false) -> Bool {
        // Keep delivery in recording order, including the asynchronous paste callback.
        let delivered = DispatchSemaphore(value: 0)
        var succeeded = false
        DispatchQueue.main.async {
            let complete: (String?) -> Void = { error in
                succeeded = error == nil && warning == nil && result != nil
                self.dictationQueue.complete(job)
                if let error { self.lastError = error; Log.write("変換結果: " + error) }
                if self.state != .recording {
                    self.progressPanel.reset()
                    self.restoreDictationState()
                }
                delivered.signal()
            }
            if let warning { complete(warning); return }
            guard let result, !result.text.isEmpty else {
                complete("入力できる文章がありませんでした。")
                return
            }
            self.lastWarnings = result.styleWarnings
            self.rememberTranscript(result.text)
            self.pendingDraft = result.text
            if requireFrontmost, target == nil || NSWorkspace.shared.frontmostApplication?.processIdentifier != target?.processIdentifier {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.text, forType: .string)
                Log.write("元のアプリが前面に無いのでクリップボードへ保存")
                complete(nil)
                self.aiPanel.show(message: "元のアプリが前面に無いのでクリップボードへ入れました。⌘Vで貼り付けてください。",
                                  actions: [.init(title: "閉じる") { [weak self] in self?.aiPanel.close() }])
                return
            }
            guard self.dictationQueue.mayAutoPaste(job), self.state != .recording,
                  !self.meeting.blocksRecording else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.text, forType: .string)
                Log.write("次の録音を優先: 変換結果をクリップボードと履歴へ保存")
                complete(nil)
                return
            }
            Inserter.insert(result.text, into: target, shouldPaste: {
                self.dictationQueue.mayAutoPaste(job) && self.state != .recording && !self.meeting.blocksRecording
            }) { error in complete(error?.localizedDescription) }
        }
        delivered.wait()
        return succeeded
    }

}

// MARK: - AI 補正の失敗からの立て直し
extension AppDelegate {
    private static let resolvedThroughKey = "recoveryResolvedThrough"
    private static let handledNamesKey = "recoveryHandledNames"

    /// 初回起動の時刻。これより前の録音はメニューに出さない。
    private var recoveryResolvedThrough: Date? { UserDefaults.standard.object(forKey: Self.resolvedThroughKey) as? Date }

    private func markRecordingsResolved(through date: Date) {
        if let current = recoveryResolvedThrough, current >= date { return }
        UserDefaults.standard.set(date, forKey: Self.resolvedThroughKey)
    }

    private var handledRecordings: Set<String> { Set(UserDefaults.standard.stringArray(forKey: Self.handledNamesKey) ?? []) }

    /// 1つの録音だけを扱い終えた印にする。ほかの録音の解決には影響させない。
    private func markRecordingHandled(_ name: String) {
        var names = handledRecordings
        names.insert(name)
        UserDefaults.standard.set(Array(names), forKey: Self.handledNamesKey)
    }

    /// まだ解決していない録音のうち、いちばん新しいもの。
    private var latestRecovery: (url: URL, date: Date)? {
        UnresolvedRecording.latest(in: recoveryFolder, resolvedThrough: ignoreRecoveryResolution ? nil : recoveryResolvedThrough,
                                   handled: ignoreRecoveryResolution ? [] : handledRecordings)
    }

    private func restorePendingPolishes() {
        failedPolishes = pendingStore.loadAll().map(FailedPolish.init(restoring:))
        if !failedPolishes.isEmpty { Log.write("未解決の文章を読み戻した: \(failedPolishes.count)件") }
    }

    /// 通常の録音の完了。前の失敗の文章と録音は解決扱いにしない。
    private func noteDictationSucceeded(usedAI: Bool, provider: AIProvider) {
        guard usedAI else { return }
        let report = { self.linkMonitor.reportPolish(nil, provider: provider) }
        if Thread.isMainThread { report() } else { DispatchQueue.main.async(execute: report) }
    }

    private func rememberFailure(_ failed: FailedPolish) {
        failedPolishes.removeAll { $0.id == failed.id }
        failedPolishes.append(failed)
        failedPolishes.sort { $0.createdAt > $1.createdAt }
    }

    /// やり直しか貼り付けが済んだ文章を、未解決の扱いから外す。
    private func resolvePolish(_ failed: FailedPolish) {
        pendingStore.remove(id: failed.id)
        removeRecovered(failed.recordingName, keepAudio: failed.keepAudio)
        DispatchQueue.main.async { self.failedPolishes.removeAll { $0.id == failed.id } }
    }

    private func recoveryTitle(_ recovery: (url: URL, date: Date)) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm"
        return "前回の録音からやり直す（\(formatter.string(from: recovery.date))）"
    }

    /// 失敗の対応が要るときだけ項目を足す。足したら true。
    private func addRecoveryMenu(to menu: NSMenu) -> Bool {
        var added = false
        func add(_ title: String, _ action: Selector) {
            menu.addItem(plainItem(title, action, enabled: state == .idle))
            added = true
        }
        if failedPolish != nil {
            let others = failedPolishes.count > 1 ? "（新しい文章から・全\(failedPolishes.count)件）" : ""
            add("AI補正をやり直す" + others, #selector(redoPolish))
            add("未補正のまま貼り付け" + others, #selector(pasteUnpolished))
        }
        if aiNeedsReconnect { add("AIに再接続", #selector(reconnectAI)) }
        if let recovery = latestRecovery { add(recoveryTitle(recovery), #selector(redoLatestRecording)) }
        return added
    }

    /// 接続に問題が残っているあいだだけ true。接続できた・補正できた時点で polishStatus が上書きされて false に戻る。
    private var aiNeedsReconnect: Bool {
        guard linkFix == nil, linkMonitor.status != .connected else { return false }
        return failedPolish != nil || (settings.polishWithClaude && (polishStatus.contains("⚠️") || polishStatus.contains("失敗")))
    }

    /// 通常モードで連携が切れているときだけ値がある。
    private var linkFix: AILinkFix? { settings.polishWithClaude ? linkMonitor.status.fix : nil }

    private static func linkDescription(_ fix: AILinkFix) -> String {
        switch fix {
        case .login(let tool, _, _): return "\(tool) のログインが切れています。押すとターミナルでログインを開きます。"
        case .key: return "APIキーが無いか、無効です。押すとキーの設定を開きます。"
        }
    }

    @objc private func loginToAI() {
        guard let fix = linkFix else { return }
        switch fix {
        case .login(let tool, let executable, let arguments):
            linkMonitor.noteLoginOpened()
            openLogin(tool: tool, executable: executable, arguments: arguments)
        case .key(let provider):
            guard state == .idle else { NSSound.beep(); return }
            if provider == .claude { showAPIKeySettings() } else { showOpenAIKeySettings() }
        }
    }

    private var loginAction: AIStatusPanel.Action? {
        guard linkFix != nil else { return nil }
        return .init(title: "AIにログイン…") { [weak self] in self?.loginToAI() }
    }

    private func showLinkNotice() {
        guard !linkNoticeShown else { return }
        linkNoticeShown = true
        var actions = [AIStatusPanel.Action(title: "閉じる") { [weak self] in self?.aiPanel.close() }]
        if case .login = linkFix, let loginAction { actions.insert(loginAction, at: 0) }
        loginPanelOpen = true
        aiPanel.show(message: "AI連携が切れています。文章は保存されます。", actions: actions, autoCloseAfter: 6)
    }

    private func linkStatusChanged(from old: AILinkStatus, to new: AILinkStatus) {
        updateStatusIcon()
        if new.fix != nil {
            Log.write("AI連携: 切れている")
            if state == .recording { showLinkNotice() }
        } else if old.fix != nil {
            Log.write("AI連携: 戻った")
            if new == .connected {
                polishStatus = Self.readyStatus(for: settings.aiProvider)
                offerPendingAfterLogin()
            }
        }
    }

    private var pendingOfferActions: [AIStatusPanel.Action] {
        guard failedPolish != nil else { return [] }
        return [.init(title: "さきほどの文章を補正する") { [weak self] in self?.redoPolish() },
                .init(title: "未補正のまま貼り付け") { [weak self] in self?.pasteUnpolished() }]
    }

    /// ログインが済んだら、未解決の文章をすぐ扱えるようにする。
    private func offerPendingAfterLogin() {
        offerPendingWhenIdle = false
        guard failedPolish != nil else {
            if loginPanelOpen { aiPanel.close(); loginPanelOpen = false }
            return
        }
        guard state == .idle else { offerPendingWhenIdle = true; return }
        loginPanelOpen = false
        aiPanel.show(message: "AIに接続できました。保存していた文章を補正できます。",
                     actions: pendingOfferActions + [.init(title: "閉じる") { [weak self] in self?.aiPanel.close() }])
    }

    private func panelActions(loginFirst: Bool = false) -> [AIStatusPanel.Action] {
        var actions: [AIStatusPanel.Action] = []
        let reconnect = AIStatusPanel.Action(title: "AIに再接続") { [weak self] in self?.reconnectAI() }
        if let loginAction { actions.append(loginAction) } else if loginFirst { actions.append(reconnect) }
        if failedPolish != nil {
            actions.append(.init(title: "AI補正をやり直す") { [weak self] in self?.redoPolish() })
            actions.append(.init(title: "未補正のまま貼り付け") { [weak self] in self?.pasteUnpolished() })
        }
        if !loginFirst && linkFix == nil { actions.append(reconnect) }
        if let recovery = latestRecovery {
            actions.append(.init(title: recoveryTitle(recovery)) { [weak self] in self?.redoLatestRecording() })
        }
        actions.append(.init(title: "閉じる") { [weak self] in self?.aiPanel.close() })
        return actions
    }

    /// 作業キューから呼ぶ。未補正文をクリップボードに残し、自動では貼り付けない。
    private func reportPolishFailure(_ error: Error, failed: FailedPolish, job: Int) {
        // 何より先にディスクへ残す。話した内容はログに書かない。
        do { try pendingStore.save(failed.pending) }
        catch { Log.write("未解決の文章を保存できない: \(error.localizedDescription)") }
        let provider = Settings.load().aiProvider
        let message = PolishRecovery.failureMessage(error, provider: provider)
        Log.write("AI補正に失敗したため貼り付けを中止: \(error.localizedDescription)")
        DispatchQueue.main.async {
            self.polishStatus = "仕上げ: 失敗（原文をコピー済み）"
            self.pendingDraft = failed.result.text
            self.rememberTranscript(failed.result.text)
            self.copyPendingDraft()
            self.rememberFailure(failed)
            self.linkMonitor.reportPolish(error, provider: provider)
        }
        finish(nil, warning: message, target: failed.target, job: job)
        DispatchQueue.main.async {
            self.loginPanelOpen = self.linkFix != nil
            self.aiPanel.show(message: message, actions: self.panelActions(loginFirst: PolishRecovery.kind(of: error) == .login))
        }
    }

    private func beginManualJob(destination: String?) -> Int {
        aiPanel.close()
        dictationQueue.beginRecording()
        let job = dictationQueue.enqueue()
        lastError = nil
        state = .processing
        progressPanel.begin(destination: destination ?? "入力先")
        return job
    }

    private func removeRecovered(_ name: String?, keepAudio: Bool) {
        guard let name else { return }
        if keepAudio { markRecordingHandled(name); return }
        try? FileManager.default.removeItem(at: recoveryFolder.appendingPathComponent(name))
    }

    private func progressCallbacks() -> (status: (String) -> Void, progress: (Int, Int) -> Void) {
        ({ message in DispatchQueue.main.async { self.progressPanel.update(message, detail: "認証を確かめ直して、失敗した文だけ再試行しています。") } },
         { done, total in DispatchQueue.main.async { self.progressPanel.update("AIで補正中", detail: "補正済み \(done)／\(total)文。全文の完了を待っています。") } })
    }

    @objc private func redoPolish() {
        guard state == .idle, let failed = failedPolish else { NSSound.beep(); return }
        let provider = Settings.load().aiProvider
        let job = beginManualJob(destination: failed.target?.localizedName)
        let callbacks = progressCallbacks()
        work.async {
            do {
                DispatchQueue.main.async { self.progressPanel.update("AIで補正中", detail: "保持した未補正文でやり直しています。") }
                Polisher.resetAuthentication()
                var output = failed.result
                output.text = try failed.resolvedJob().run(status: callbacks.status, progress: callbacks.progress)
                DispatchQueue.main.async {
                    self.polishStatus = "仕上げ: やり直しで補正できました"
                    self.linkMonitor.reportPolish(nil, provider: provider)
                }
                if self.finish(output, warning: nil, target: failed.target, job: job, requireFrontmost: true) { self.resolvePolish(failed) }
            } catch {
                self.reportPolishFailure(error, failed: failed, job: job)
            }
        }
    }

    @objc private func pasteUnpolished() {
        guard state == .idle, let failed = failedPolish else { NSSound.beep(); return }
        let job = beginManualJob(destination: failed.target?.localizedName)
        work.async {
            if self.finish(failed.result, warning: nil, target: failed.target, job: job, requireFrontmost: true) { self.resolvePolish(failed) }
        }
    }

    @objc private func redoLatestRecording() {
        guard state == .idle, let recovery = latestRecovery else { NSSound.beep(); return }
        let target = NSWorkspace.shared.frontmostApplication
        let job = beginManualJob(destination: target?.localizedName)
        let settings = Settings.load()
        self.settings = settings
        let name = recovery.url.lastPathComponent
        let linked = failedPolishes.first { $0.recordingName == name }
        let callbacks = progressCallbacks()
        work.async {
            guard let whisper = settings.resolvedWhisper else {
                self.finish(nil, warning: Transcriber.TranscribeError.whisperMissing.localizedDescription, target: target, job: job)
                return
            }
            let client = settings.selectedClientFolder.isEmpty ? nil : ReferencePreparation(folder: settings.selectedClientFolder).wait()
            if settings.polishWithClaude && !settings.selectedClientFolder.isEmpty && (client == nil || client!.unavailable || client!.referenceText.isEmpty) {
                self.finish(nil, warning: "顧客辞書を準備できませんでした。資料を確認してください。未補正文は貼り付けません。", target: target, job: job)
                return
            }
            let terms = TermDictionary.load()
            let aliases = settings.clientNameAliases[settings.selectedClientFolder] ?? [:]
            let transcriber = Transcriber(whisperPath: whisper, modelPath: settings.resolvedModel, language: settings.language,
                                          initialPrompt: client?.initialPrompt(dictionary: terms.initialPrompt, screen: nil, aliases: aliases) ?? terms.initialPrompt,
                                          fastMode: !settings.polishWithClaude, useMLX: settings.mlxForDictation)
            let raw: String
            do { raw = Hallucination.clean(try transcriber.transcribe(recovery.url)) }
            catch {
                self.finish(nil, warning: error.localizedDescription, target: target, job: job)
                return
            }
            guard !raw.isEmpty, !Hallucination.isOnly(raw) else {
                self.markRecordingHandled(name)
                self.finish(nil, warning: "この録音からは文字を取れませんでした。", target: target, job: job)
                return
            }
            let formatter = Formatter(terms: terms, forbiddenWords: StyleWords.load(from: settings.styleWordsPath),
                                      dropSelfCorrections: settings.dropSelfCorrections, spaceAroundLatin: settings.spaceAroundLatin,
                                      trimTrailingPeriod: settings.trimTrailingPeriod)
            var result = formatter.format(raw)
            let polishJob = PolishJob(text: result.text, model: settings.polishModel, effort: settings.polishEffort, context: nil, client: client,
                                      aliases: aliases, instructions: settings.customPolishInstructions, jevSettings: settings.jev)
            // 同じ録音の文章がすでに未解決なら、増やさず置き換える。
            let failed = FailedPolish(id: linked?.id ?? UUID().uuidString, createdAt: linked?.createdAt ?? Date(), result: result, job: polishJob, target: target,
                                      recordingName: name, keepAudio: settings.keepAudioForDebug, clientFolder: settings.selectedClientFolder)
            if settings.polishWithClaude {
                do { result.text = try polishJob.run(status: callbacks.status, progress: callbacks.progress) }
                catch { self.reportPolishFailure(error, failed: failed, job: job); return }
            }
            guard !Transcriber.hasRunawayRepetition(result.text) else {
                self.markRecordingHandled(name)
                self.finish(nil, warning: "異常な反復を検出したため貼り付けを止めました。録音はMacの復旧用フォルダに保持します。", target: target, job: job)
                return
            }
            self.noteDictationSucceeded(usedAI: settings.polishWithClaude, provider: settings.aiProvider)
            guard self.finish(result, warning: nil, target: target, job: job, requireFrontmost: true) else { return }
            self.removeRecovered(name, keepAudio: settings.keepAudioForDebug)
            if let linked { self.pendingStore.remove(id: linked.id); DispatchQueue.main.async { self.failedPolishes.removeAll { $0.id == linked.id } } }
        }
    }

    @objc private func reconnectAI() {
        guard state == .idle else { NSSound.beep(); return }
        let provider = Settings.load().aiProvider
        polishStatus = "仕上げ: \(provider.shortName) への接続を確認中"
        aiPanel.show(message: "\(provider.shortName) への接続を確かめています。", actions: [])
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = AIConnection.reconnect(provider: provider)
            DispatchQueue.main.async { self.present(outcome, provider: provider) }
        }
    }

    private func present(_ outcome: AIConnection.Outcome, provider: AIProvider) {
        linkMonitor.reportReconnect(outcome, provider: provider)
        loginPanelOpen = false
        let close = AIStatusPanel.Action(title: "閉じる") { [weak self] in self?.aiPanel.close() }
        let again = AIStatusPanel.Action(title: "AIに再接続") { [weak self] in self?.reconnectAI() }
        switch outcome {
        case .connected(let name):
            polishStatus = "仕上げ: \(name) に接続できました"
            lastError = nil
            updateStatusIcon()
            aiPanel.show(message: "\(name) に接続できました。", actions: pendingOfferActions + [close])
        case .needsLogin(let tool, let executable, let arguments):
            polishStatus = "仕上げ: ⚠️ \(tool) のログインが必要"
            let login = AIStatusPanel.Action(title: "ターミナルで \(tool) にログイン") { [weak self] in
                self?.linkMonitor.noteLoginOpened()
                self?.openLogin(tool: tool, executable: executable, arguments: arguments)
            }
            loginPanelOpen = true
            aiPanel.show(message: "\(tool) のログインが切れています。ターミナルでログインすると自動で確かめます。", actions: [login, again, close])
        case .needsKey(let keyProvider):
            polishStatus = "仕上げ: ⚠️ APIキーを確認してください"
            let setKey = AIStatusPanel.Action(title: "APIキーを設定…") { [weak self] in
                self?.aiPanel.close()
                if keyProvider == .claude { self?.showAPIKeySettings() } else { self?.showOpenAIKeySettings() }
            }
            aiPanel.show(message: "APIキーが無いか、無効です。キーを入れたあと、「AIに再接続」を押してください。", actions: [setKey, again, close])
        case .failed(let reason):
            polishStatus = "仕上げ: ⚠️ \(provider.shortName) に接続できません"
            aiPanel.show(message: "\(provider.shortName) に接続できませんでした。\(reason)", actions: [again, close])
        }
    }

    private func openLogin(tool: String, executable: String, arguments: [String]) {
        do {
            NSWorkspace.shared.open(try AIConnection.writeLoginScript(tool: tool, executable: executable, arguments: arguments))
            Log.write("\(tool) のログインをターミナルで開いた")
        } catch {
            aiPanel.show(message: "ターミナルを開けませんでした。\(error.localizedDescription)", actions: [])
        }
    }
}

extension AppDelegate {
    /// キーチェーンを読むので、自己テスト中は触らない（許可のダイアログを出さない）。
    private var googleDrive: MeetingGoogleDrive? { avoidKeychainForCheck ? nil : MeetingGoogleDrive.shared }

    private func meetingMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "会議", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        if meeting.status != "会議モード・待機中" {
            submenu.addItem(plainItem(meeting.status, nil, enabled: false))
            submenu.addItem(.separator())
        }
        submenu.addItem(plainItem("最新の議事録を開く", #selector(openMeetingDocument), enabled: meeting.latestURL != nil))
        submenu.addItem(plainItem("議事録一覧を開く", #selector(openMeetingList), enabled: googleDrive?.folderURL != nil))
        submenu.addItem(.separator())
        submenu.addItem(plainItem("未保存の会議を再処理", #selector(retryMeeting), enabled: state == .idle && !meeting.isBusy && MeetingRecord.recent().contains { $0.status != "saved" }))
        submenu.addItem(plainItem("会議データを Finder で開く", #selector(openMeetingData)))
        submenu.addItem(.separator())
        submenu.addItem(plainItem(googleDrive?.isAuthenticated == true ? "Google連携を変更…" : "Googleドライブを連携…", #selector(connectMeetingGoogle), enabled: !meeting.isBusy && state == .idle))
        root.submenu = submenu
        return root
    }
    @objc private func connectMeetingGoogle() {
        guard state == .idle, !meeting.isBusy else { return }
        MeetingGoogleDrive.shared.connect { [weak self] result in
            switch result {
            case .success: self?.lastError = nil
            case .failure(let error):
                self?.lastError = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Google連携を完了できませんでした"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "閉じる")
                alert.runModal()
            }
            self?.updateStatusIcon()
        }
    }
    @objc private func diagnoseScreenContext() {
        guard Settings.load().useScreenContext else { return }
        let target = NSWorkspace.shared.frontmostApplication
        DispatchQueue.global(qos: .userInitiated).async {
            let context = ScreenContext.capture(app: target)
            Log.write("常駐画面診断 app=\(target?.bundleIdentifier ?? "unknown") chars=\(context?.focusedText.count ?? 0)（本文非保存）")
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

// MARK: - メニューの確認
extension AppDelegate {
    /// メニューと設定を実物で見るための起動。録音も通信もせず、3分で終わる。
    /// --menu-preview-normal / --menu-preview-failed はメニューを開き、--menu-preview-settings は設定を開く。
    private func startMenuPreview(_ kind: String) {
        meetWatchTimer?.invalidate()
        meeting.suspendBackgroundRetry()
        hotKeyRegistered = true
        if kind == "--menu-preview-failed" {
            fillFailedStateForCheck()
            ignoreRecoveryResolution = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if kind == "--menu-preview-settings" { self.showPreferences() } else { self.statusItem.button?.performClick(nil) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { exit(0) }
    }

    private func fillFailedStateForCheck() {
        let result = FormatResult(text: "確認用の文章です")
        let job = PolishJob(text: result.text, model: "", effort: "", context: nil, client: nil, aliases: [:], instructions: "", jevSettings: settings.jev)
        failedPolishes = [FailedPolish(result: result, job: job, target: nil, recordingName: nil, keepAudio: true, clientFolder: "")]
        polishStatus = "仕上げ: 失敗（原文をコピー済み）"
        lastError = PolishRecovery.failureMessage(Polisher.PolishError.maxLoginRequired, provider: .claude)
        history = [result.text]
        pendingDraft = result.text
        updateStatusIcon()
    }

    static func runMenuLayoutTests() -> Bool {
        var passed = true
        func check(_ name: String, _ good: Bool) { print((good ? "PASS: " : "FAIL: ") + name); passed = passed && good }
        let app = AppDelegate()
        app.meeting.suspendBackgroundRetry()
        app.avoidKeychainForCheck = true
        app.settings.polishWithClaude = false   // 接続先の確認でキーチェーンを読まない
        app.hotKeyRegistered = true
        app.polishStatus = "仕上げ: 確認"
        func titles() -> (top: [String], all: [String]) {
            let menu = NSMenu()
            app.menuNeedsUpdate(menu)
            let top = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
            let inner = menu.items.compactMap(\.submenu).flatMap(\.items).filter { !$0.isSeparatorItem }.map(\.title)
            return (top, top + inner)
        }
        let normal = titles()
        check("普段のメニューは10項目以内", normal.top.count <= 10)
        check("普段のメニューに主要な操作がある", ["録音を始める", "履歴", "通常モード", "高速入力モード", "会議", "設定…", "音声入力を終了"].allSatisfy(normal.top.contains))
        check("普段のメニューに失敗の操作を出さない", !normal.all.contains { $0 == "AIに再接続" || $0 == "AI補正をやり直す" || $0 == "未補正のまま貼り付け" })
        check("普段のメニューに内部の情報を出さない", !normal.all.contains { $0.hasPrefix("画面参照") || $0.hasPrefix("顧客") || $0.hasPrefix("仕上げ:") || $0.contains("⌥Space") })
        let menu = NSMenu()
        app.menuNeedsUpdate(menu)
        check("録音の項目に ⌥Space を出す", menu.items.first { $0.title == "録音を始める" }?.keyEquivalent == " ")
        app.fillFailedStateForCheck()
        let failed = titles()
        check("失敗中のメニューも12項目以内", failed.top.count <= 12)
        check("失敗中は復旧の操作を上に出す", ["AI補正をやり直す", "未補正のまま貼り付け", "AIに再接続"].allSatisfy(failed.top.contains))
        check("失敗中は先頭に1行だけ知らせる", failed.top.first?.hasPrefix("⚠️") == true && failed.top.filter { $0.hasPrefix("⚠️") }.count == 1)
        check("失敗の1行は短い", (failed.top.first?.count ?? 99) <= 40)
        app.pendingDraft = "変換の途中の文"
        check("履歴の先頭に無い文字起こしは履歴から取れる", titles().all.contains("直前の文字起こし結果をコピー"))
        app.pendingDraft = app.history.first
        check("履歴と同じなら直前のコピーを重ねない", !titles().all.contains("直前の文字起こし結果をコピー"))
        return passed
    }

    /// 連携切れのメニューと、再起動をまたいだ未解決の文章を確かめる。呼び出し側がキーを隠し、偽の CLI を用意する。
    static func runLinkMenuTests(folder: URL, cliPath: String) -> Bool {
        var passed = true
        func check(_ name: String, _ good: Bool) { print((good ? "PASS: " : "FAIL: ") + name); passed = passed && good }
        func makeApp() -> AppDelegate {
            let app = AppDelegate()
            app.meeting.suspendBackgroundRetry()
            app.avoidKeychainForCheck = true
            app.hotKeyRegistered = true
            app.polishStatus = "仕上げ: 確認"
            app.settings.polishWithClaude = true
            app.settings.aiProvider = .claude
            app.settings.selectedClientFolder = ""
            app.recoveryFolder = folder
            app.pendingStore = PendingPolishStore(folder: folder)
            return app
        }
        func titles(_ app: AppDelegate) -> [String] {
            let menu = NSMenu()
            app.menuNeedsUpdate(menu)
            return menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        }
        let everyday = ["録音を始める", "履歴", "通常モード", "高速入力モード", "会議", "設定…", "音声入力を終了"]
        var loggedIn = true
        let app = makeApp()
        let monitor = AILinkMonitor(activeProvider: { [unowned app] in app.settings.polishWithClaude ? app.settings.aiProvider : nil },
                                    light: { _ in if !loggedIn { throw Polisher.PolishError.maxLoginRequired } }, probe: { _ in }, inline: true)
        app.linkMonitor = monitor
        monitor.onChange = { [unowned app] old, new in app.linkStatusChanged(from: old, to: new) }
        monitor.checkNow()
        check("つながっていれば AIにログイン を出さない", !titles(app).contains("AIにログイン…"))
        check("つながっていれば普段の7項目のまま", titles(app).filter { !$0.hasPrefix("⚠️") } == everyday)   // 試験の実行ファイルには権限の知らせが出る
        loggedIn = false
        monitor.checkNow()
        let down = titles(app)
        check("切れたらメニューの先頭が AIにログイン", down.first == "AIにログイン…")
        check("切れていても録音など普段の項目はそのまま", everyday.allSatisfy(down.contains))
        check("切れているときは AIに再接続 を重ねない", !down.contains("AIに再接続"))
        let downMenu = NSMenu()
        app.menuNeedsUpdate(downMenu)
        check("録音の項目は押せる", downMenu.items.first { $0.title == "録音を始める" }?.isEnabled == true)
        check("AIにログイン は押せる", downMenu.items.first?.isEnabled == true && downMenu.items.first?.target === app && downMenu.items.first?.action == #selector(loginToAI))
        app.settings.polishWithClaude = false
        check("高速入力モードでは AIにログイン を出さない", !titles(app).contains("AIにログイン…"))
        app.settings.polishWithClaude = true
        monitor.checkNow()
        loggedIn = true
        monitor.checkNow()
        check("ログインが済むと AIにログイン が消える", !titles(app).contains("AIにログイン…"))
        monitor.reportPolish(Polisher.PolishError.usageLimit, provider: .claude)
        let limited = titles(app)
        check("利用上限ではログインを促さない", !limited.contains("AIにログイン…"))
        check("利用上限は先頭に説明を出す", limited.first?.hasPrefix("⚠️") == true && limited.first?.contains("利用上限") == true)

        // 再起動相当: 別の AppDelegate が同じフォルダから読み戻す
        let store = PendingPolishStore(folder: folder)
        let item = PendingPolish(id: UUID().uuidString, createdAt: Date(), text: "試験の長い文章です。", styleWarnings: [], targetBundleID: nil,
                                 recordingName: "rec-pending.wav", keepAudio: false, clientFolder: "")
        check("未解決の文章を保存できる", (try? store.save(item)) != nil)
        let restarted = makeApp()
        restarted.restorePendingPolishes()
        let restored = titles(restarted)
        check("再起動しても AI補正をやり直す が使える", restored.contains("AI補正をやり直す"))
        check("再起動しても 未補正のまま貼り付け が使える", restored.contains("未補正のまま貼り付け"))
        check("再起動しても本文が残る", restarted.failedPolish?.result.text == item.text)
        if let failed = restarted.failedPolish {
            check("再起動後のやり直しで補正できる", (try? failed.resolvedJob().run()) == "整形後の文。")
        } else { check("再起動後のやり直しで補正できる", false) }

        // 後の録音の成功では消さない
        let wav = folder.appendingPathComponent("rec-pending.wav")
        FileManager.default.createFile(atPath: wav.path, contents: Data(count: 40_000))
        restarted.noteDictationSucceeded(usedAI: true, provider: .claude)
        check("後の録音が成功しても文章は未解決のまま", restarted.failedPolish?.id == item.id && store.loadAll().count == 1)
        check("後の録音が成功しても録音ファイルは未解決のまま", restarted.latestRecovery?.url.lastPathComponent == "rec-pending.wav")
        restarted.linkMonitor = AILinkMonitor(activeProvider: { .claude }, light: { _ in }, probe: { _ in }, inline: true)
        restarted.linkMonitor.checkNow()
        check("つながっていれば未解決の文章があっても AIに再接続 を出さない", !titles(restarted).contains("AIに再接続"))

        // 新しいものから扱い、解決したら外す
        if let failed = restarted.failedPolish {
            restarted.pendingStore.remove(id: failed.id)
            restarted.removeRecovered(failed.recordingName, keepAudio: failed.keepAudio)
            restarted.failedPolishes.removeAll { $0.id == failed.id }
        }
        check("解決した文章はメニューから消える", !titles(restarted).contains("AI補正をやり直す") && store.loadAll().isEmpty)
        check("解決した録音は消える", !FileManager.default.fileExists(atPath: wav.path))
        return passed
    }
}
