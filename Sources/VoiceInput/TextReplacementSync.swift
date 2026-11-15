import AppKit
import ApplicationServices

/// 英字の用語を Mac のユーザ辞書（システム設定 → キーボード → ユーザ辞書）へ週1回写す。
/// データベースには書かない。システム設定の画面を操作して足し、入ったかはデータベースを読み取り専用で開いて確かめる。
/// オーナーが手で入れた語は消さない・変えない。同じ入力（読み）か同じ語句がすでにあれば足さない。
enum TextReplacementSync {
    struct Pair: Codable, Hashable { var shortcut: String; var phrase: String }

    struct State: Codable {
        var lastSuccess: Date?
        /// 失敗した日時（中断は含めない）。失敗の直後に何度も画面を動かさないために使う。
        var lastFailure: Date?
        var lastError: String?
        var verifiedAt: Date?
        var verifiedOS: String?
        var testFailures: Int = 0
        var lastTestFailure: Date?
        /// このアプリが足した組（外すときの手がかり。オーナーの語は入れない）
        var added: [Pair] = []
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastSuccess = try c.decodeIfPresent(Date.self, forKey: .lastSuccess)
            lastFailure = try c.decodeIfPresent(Date.self, forKey: .lastFailure)
            lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
            added = try c.decodeIfPresent([Pair].self, forKey: .added) ?? []
            verifiedAt = try c.decodeIfPresent(Date.self, forKey: .verifiedAt)
            verifiedOS = try c.decodeIfPresent(String.self, forKey: .verifiedOS)
            testFailures = try c.decodeIfPresent(Int.self, forKey: .testFailures) ?? 0
            lastTestFailure = try c.decodeIfPresent(Date.self, forKey: .lastTestFailure)
        }

        func isVerified(currentOS: String) -> Bool {
            verifiedAt != nil && verifiedOS == currentOS
        }

        /// OS が変わったら、保存済みの実機試験の印を取り消す。
        @discardableResult
        mutating func invalidateVerification(currentOS: String) -> Bool {
            guard verifiedOS != currentOS, verifiedAt != nil || verifiedOS != nil else { return false }
            verifiedAt = nil; verifiedOS = nil
            return true
        }
    }

    static let interval: TimeInterval = 7 * 86400
    static let retryAfterFailure: TimeInterval = 6 * 3600
    static let requiredIdle: TimeInterval = 300
    static let maxPerRun = 30
    static let testPair = Pair(shortcut: "vitestzz", phrase: "VoiceInputTestZZ")

    static var stateURL: URL { Paths.root.appendingPathComponent("text-replacements.json") }
    static var exportURL: URL { Paths.root.appendingPathComponent("text-replacements", isDirectory: true).appendingPathComponent("voice-input-terms.plist") }
    static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/KeyboardServices/TextReplacements.db")
    }

    /// ロック中・ディスプレイ消灯中は画面を操作しない。セッションを確認できない場合も止める。
    static var screenAvailable: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) != true
            && CGDisplayIsAsleep(CGMainDisplayID()) == 0
    }

    // MARK: - 写す語を決める（純粋な計算）

    /// 英字の語だけ（例: freee・UTAGE・GitHub）。日本語の語・住所・定型文はここで落ちる。
    static func isLatinTerm(_ phrase: String) -> Bool {
        phrase.range(of: #"^[A-Za-z][A-Za-z0-9 .&_\-]{1,39}$"#, options: .regularExpression) != nil
    }

    /// 入力（読み）は英字で打つ前提。読みは推測せず、語句を小文字にして英数字だけを残す。
    static func shortcut(for phrase: String) -> String? {
        let s = phrase.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return s.count >= 2 ? s : nil
    }

    /// 手書きの辞書と自動で足した語の登録済みから、写す組を作る。人名・顧客名・住所・定型文は入れない。
    static func candidates(manual: TermDictionary, learned: LearnedTermsFile, excludedNames: Set<String>) -> [Pair] {
        let skipNotes = ["住所", "人名", "氏名", "顧客", "社名", "会社名", "定型"]
        let excluded = Set(excludedNames.map { $0.lowercased() })
        var phrases: [String] = []
        for entry in manual.entries where !skipNotes.contains(where: { entry.note.contains($0) }) { phrases.append(entry.correct) }
        phrases += learned.pairs.filter(\.registered).map(\.correct)
        var seen = Set<String>()
        return phrases.compactMap { phrase -> Pair? in
            let p = phrase.trimmingCharacters(in: .whitespaces)
            guard isLatinTerm(p), !excluded.contains(p.lowercased()), seen.insert(p.lowercased()).inserted,
                  let s = shortcut(for: p) else { return nil }
            return Pair(shortcut: s, phrase: p)
        }
    }

    /// 顧客資料から作った辞書（端末内のキャッシュ）の人名・社名・住所・地名。英字の顧客名を写さないため。
    static func excludedNames(folder: URL = Paths.root.appendingPathComponent("client-dictionaries", isDirectory: true)) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var names = Set<String>()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), data.count <= 2_000_000,
                  let cache = try? JSONDecoder().decode(ClientDictionary.Cache.self, from: data) else { continue }
            for entry in cache.entries where ["person", "company", "address", "place"].contains(entry.kind) {
                names.insert(entry.name)
                if !entry.company.isEmpty { names.insert(entry.company) }
            }
        }
        return names
    }

    /// すでにある語と重ねない。同じ入力（読み）か同じ語句があれば足さない（大小は区別しない）。
    static func plan(_ candidates: [Pair], existing: [Pair]) -> [Pair] {
        var shortcuts = Set(existing.map { $0.shortcut.lowercased() })
        var phrases = Set(existing.map { $0.phrase.lowercased() })
        return candidates.filter {
            let shortcut = $0.shortcut.lowercased(), phrase = $0.phrase.lowercased()
            guard !shortcuts.contains(shortcut), !phrases.contains(phrase) else { return false }
            shortcuts.insert(shortcut); phrases.insert(phrase)
            return true
        }
    }

    /// 週1回。録音・会議中でなく、キーボードとマウスを5分以上触っていないときだけ。失敗の直後は6時間あける。
    static func shouldRun(now: Date, state: State, idleSeconds: TimeInterval, busy: Bool, screenAvailable: Bool) -> Bool {
        guard screenAvailable, !busy, idleSeconds >= requiredIdle else { return false }
        if let failure = state.lastFailure, now.timeIntervalSince(failure) < retryAfterFailure { return false }
        guard let success = state.lastSuccess else { return true }
        return now.timeIntervalSince(success) >= interval
    }

    enum Action: Equatable { case none, liveTest, sync }

    static func nextAction(now: Date, state: State, currentOS: String, idleSeconds: TimeInterval,
                           busy: Bool, screenAvailable: Bool) -> Action {
        guard screenAvailable, !busy, idleSeconds >= requiredIdle else { return .none }
        guard state.isVerified(currentOS: currentOS) else {
            if state.testFailures > 0, let failure = state.lastTestFailure {
                let wait: TimeInterval = state.testFailures == 1 ? 30 * 60 : (state.testFailures == 2 ? 2 * 3600 : 6 * 3600)
                if now.timeIntervalSince(failure) < wait { return .none }
            }
            return .liveTest
        }
        // 実機試験直後の初回でも、本番取り込みの失敗後は6時間あける。
        if let failure = state.lastFailure, now.timeIntervalSince(failure) < retryAfterFailure { return .none }
        if let verified = state.verifiedAt, state.lastSuccess.map({ $0 < verified }) ?? true { return .sync }
        return shouldRun(now: now, state: state, idleSeconds: idleSeconds, busy: busy,
                         screenAvailable: screenAvailable) ? .sync : .none
    }

    /// 操作の途中でオーナーが触ったか。最後の入力が、こちらが最後に送った操作より後なら触ったとみなす。
    static func touched(secondsSinceInput: TimeInterval, now: Date, lastSynthetic: Date) -> Bool {
        secondsSinceInput + 0.25 < now.timeIntervalSince(lastSynthetic)
    }

    // MARK: - ファイル

    static func loadState(_ url: URL = stateURL) -> State {
        guard let data = try? Data(contentsOf: url) else { return State() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(State.self, from: data)) ?? State()
    }

    static func saveState(_ state: State, to url: URL = stateURL) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 写す語を、ユーザ辞書の書き出しと同じ形の plist に残す（手で見返す・取り込むとき用）。
    static func writeExport(_ pairs: [Pair], to url: URL = exportURL) {
        let array = pairs.map { ["phrase": $0.phrase, "shortcut": $0.shortcut] }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: array, format: .xml, options: 0) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// ユーザ辞書のデータベースを読み取り専用で開き、今ある語（削除済みを除く）を返す。書き込みは一切しない。
    static func existing(database: URL = databaseURL) throws -> [Pair] {
        // 初めて使う Mac では、画面から登録するまでファイル自体がない。
        // 読めないファイルまで空扱いにすると重ねて登録するので、不在だけを許す。
        do {
            _ = try database.resourceValues(forKeys: [.isRegularFileKey])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        } catch {
            throw UIError.database
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        var components = URLComponents()
        components.scheme = "file"; components.path = database.path
        components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        process.arguments = ["-readonly", "-json", components.string ?? database.path,
                             "SELECT ZSHORTCUT AS shortcut, ZPHRASE AS phrase FROM ZTEXTREPLACEMENTENTRY WHERE IFNULL(ZWASDELETED,0)=0;"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UIError.database }
        if data.allSatisfy({ $0 == 0x0a || $0 == 0x20 }) { return [] }
        struct Row: Decodable { let shortcut: String?; let phrase: String? }
        let rows = try JSONDecoder().decode([Row].self, from: data)
        return rows.compactMap { r in r.shortcut.flatMap { s in r.phrase.map { Pair(shortcut: s, phrase: $0) } } }
    }

    enum UIError: Error, LocalizedError {
        case notTrusted, interrupted, database, notFound(String), notAdded(String), notRemoved(String)
        var errorDescription: String? {
            switch self {
            case .notTrusted: return "アクセシビリティの許可が無いので、システム設定を操作できません"
            case .interrupted: return "画面が使えないか、操作の途中でキーボードかマウスが使われたので止めました"
            case .database: return "ユーザ辞書のデータベースを読めませんでした"
            case .notFound(let what): return "システム設定に「\(what)」が見つかりません（macOS の更新で画面が変わった可能性があります）"
            case .notAdded(let phrase): return "「\(phrase)」を足せませんでした（画面で入れたあとデータベースに出てきません）"
            case .notRemoved(let phrase): return "試験の語「\(phrase)」を外せませんでした"
            }
        }
    }
}

/// システム設定を前に出して操作する。オーナーが触ったらすぐ止める（UIError.interrupted）。
/// 終わったら（失敗・中断でも）クリップボードを戻し、もとのアプリを前に戻す。
final class TextReplacementUI {
    typealias Pair = TextReplacementSync.Pair
    typealias UIError = TextReplacementSync.UIError
    private static let bundleID = "com.apple.systempreferences"
    private var lastSynthetic = Date()
    private let source = CGEventSource(stateID: .privateState)
    private let database: URL

    init(database: URL = TextReplacementSync.databaseURL) { self.database = database }

    /// 足す（add）と外す（remove。試験の語だけ）。呼び出しはメインスレッド以外から。
    func run(add: [Pair], remove: [Pair] = []) throws {
        try checkScreen()
        guard AXIsProcessTrusted() else { throw UIError.notTrusted }
        let previous = onMain { NSWorkspace.shared.frontmostApplication }
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        let saved = onMain { Self.savePasteboard() }
        lastSynthetic = Date()
        defer {
            onMain {
                Self.restorePasteboard(saved)
                if !wasRunning { NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).forEach { $0.terminate() } }
                if let previous, previous.bundleIdentifier != Self.bundleID, TextReplacementSync.screenAvailable {
                    Self.bringToFront(previous)
                }
            }
        }
        // キーボードの設定を開き、「ユーザ辞書…」を押す
        try checkScreen()
        _ = onMain { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!) }
        guard let app = try wait(8, { NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first }) else { throw UIError.notFound("システム設定") }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        onMain { Self.bringToFront(app) }
        guard try wait(5, { self.onMain { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier } ? true : nil }) != nil
        else { throw UIError.notFound("システム設定を前に出せない") }
        mark()
        var lastFrontRequest = Date()
        guard let dictionaryButton = try wait(10, {
            if Date().timeIntervalSince(lastFrontRequest) >= 1 {
                self.onMain { Self.bringToFront(app) }
                lastFrontRequest = Date()
            }
            return self.find(in: axApp, role: kAXButtonRole, names: ["ユーザ辞書…", "ユーザ辞書...", "Text Replacements…", "Text Replacements..."])
        })
        else { throw UIError.notFound("ユーザ辞書…") }
        try checkpoint(app)
        try press(dictionaryButton)
        guard try wait(5, { self.find(in: axApp, role: kAXButtonRole, names: ["追加", "Add"], sheetOnly: true) }) != nil else { throw UIError.notFound("追加") }

        for pair in add {
            try checkpoint(app)
            guard let addButton = find(in: axApp, role: kAXButtonRole, names: ["追加", "Add"], sheetOnly: true) else { throw UIError.notFound("追加") }
            try press(addButton)
            Thread.sleep(forTimeInterval: 0.9)
            try checkpoint(app)
            // 入力欄はアクセシビリティに出てこないので、前面で貼り付けて入れる（日本語入力の変換を通さない）
            try paste(pair.shortcut)
            try key(48)                           // Tab → 変換/語句
            Thread.sleep(forTimeInterval: 0.2)
            try paste(pair.phrase)
            try checkpoint(app)
            try key(36)                           // Return → 追加
            let added = try wait(5, { (try? TextReplacementSync.existing(database: self.database))?.contains(pair) == true ? true : nil }) ?? false
            if !added { try key(53); throw UIError.notAdded(pair.phrase) }   // Esc で入力の窓を閉じてから止める
            Thread.sleep(forTimeInterval: 0.4)
        }

        for pair in remove {
            try checkpoint(app)
            guard let row = findRow(in: axApp, pair: pair) else { throw UIError.notRemoved(pair.phrase) }
            AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 0.3)
            guard let removeButton = find(in: axApp, role: kAXButtonRole, names: ["削除", "Remove"], sheetOnly: true) else { throw UIError.notFound("削除") }
            try press(removeButton)
            let gone = try wait(5, { (try? TextReplacementSync.existing(database: self.database)).map { !$0.contains(pair) } == true ? true : nil }) ?? false
            if !gone { throw UIError.notRemoved(pair.phrase) }
        }

        if let done = find(in: axApp, role: kAXButtonRole, names: ["完了", "Done"], sheetOnly: true) { try press(done) }
    }

    // MARK: - 触ったら止める

    private func mark() { lastSynthetic = Date() }

    private func checkScreen() throws {
        guard TextReplacementSync.screenAvailable else { throw UIError.interrupted }
    }

    /// LSUIElement からの activate() だけでは macOS 14 以降で前面にならない。
    private static func bringToFront(_ app: NSRunningApplication) {
        guard TextReplacementSync.screenAvailable else { return }
        app.activate()
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                     kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    private func checkpoint(_ app: NSRunningApplication) throws {
        try checkScreen()
        let anyInput = CGEventType(rawValue: ~0)!
        let since = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
        if TextReplacementSync.touched(secondsSinceInput: since, now: Date(), lastSynthetic: lastSynthetic) { throw UIError.interrupted }
        let front = onMain { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        if front != app.processIdentifier { throw UIError.interrupted }
    }

    // MARK: - 入力を送る

    private func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
        try checkScreen()
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        mark()
        Thread.sleep(forTimeInterval: 0.08)
    }

    private func paste(_ text: String) throws {
        try checkScreen()
        onMain { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        try key(9, flags: .maskCommand)       // ⌘V
        Thread.sleep(forTimeInterval: 0.25)
    }

    private func press(_ element: AXUIElement) throws {
        try checkScreen()
        AXUIElementPerformAction(element, kAXPressAction as CFString)
        mark()
    }

    // MARK: - 画面の部品を探す

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementSetMessagingTimeout(element, 0.5)
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func windows(_ app: AXUIElement) -> [AXUIElement] {
        attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    func find(in app: AXUIElement, role: String, names: [String], sheetOnly: Bool = false) -> AXUIElement? {
        var queue: [AXUIElement] = []
        for window in windows(app) {
            if sheetOnly { queue += children(window).filter { attribute($0, kAXRoleAttribute) as? String == kAXSheetRole } }
            else { queue.append(window) }
        }
        var visited = 0
        while !queue.isEmpty, visited < 4000 {
            let node = queue.removeFirst(); visited += 1
            let nodeRole = attribute(node, kAXRoleAttribute) as? String
            if nodeRole == role {
                let labels = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute(node, $0) as? String }
                if labels.contains(where: names.contains) { return node }
            }
            // 語の一覧（行が多い）は中を見ない。ボタンは一覧の外にある
            if nodeRole == kAXOutlineRole || nodeRole == kAXTableRole { continue }
            queue += children(node)
        }
        return nil
    }

    /// 一覧から、入力と語句がこの組と同じ行を探す（試験の語を外すときだけ使う）。
    private func findRow(in app: AXUIElement, pair: Pair) -> AXUIElement? {
        for window in windows(app) {
            for sheet in children(window) where attribute(sheet, kAXRoleAttribute) as? String == kAXSheetRole {
                var queue = children(sheet)
                while !queue.isEmpty {
                    let node = queue.removeFirst()
                    let role = attribute(node, kAXRoleAttribute) as? String
                    if role == kAXOutlineRole || role == kAXTableRole {
                        for row in attribute(node, kAXRowsAttribute) as? [AXUIElement] ?? [] {
                            if values(row).contains(pair.shortcut) && values(row).contains(pair.phrase) { return row }
                        }
                        continue
                    }
                    queue += children(node)
                }
            }
        }
        return nil
    }

    private func values(_ element: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 5 else { return [] }
        var out: [String] = []
        if let v = attribute(element, kAXValueAttribute) as? String { out.append(v) }
        for child in children(element) { out += values(child, depth: depth + 1) }
        return out
    }

    // MARK: - 小物

    private func wait<T>(_ seconds: TimeInterval, _ probe: () -> T?) throws -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            try checkScreen()
            let value = probe()
            try checkScreen()
            if let value { return value }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        try checkScreen()
        return nil
    }

    private func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }

    typealias SavedItem = [(NSPasteboard.PasteboardType, Data)]
    static func savePasteboard() -> [SavedItem] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
    }
    static func restorePasteboard(_ saved: [SavedItem]) {
        NSPasteboard.general.clearContents()
        let items = saved.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { NSPasteboard.general.writeObjects(items) }
    }
}

/// 週1回の取り込みを回す。AppDelegate が10分ごとに呼ぶ。結果はログ（件数と語）と状態ファイルに残す。
final class TextReplacementRunner {
    private let queue = DispatchQueue(label: "com.ishot.voice-input.text-replacements")
    private var running = false
    private let lock = NSLock()
    /// 失敗したときの知らせ（メニューの「!」）。成功したら消す。
    var onIssue: ((String?) -> Void)?

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    private var currentOS: String { ProcessInfo.processInfo.operatingSystemVersionString }

    private func currentState() -> TextReplacementSync.State {
        var state = TextReplacementSync.loadState()
        if state.invalidateVerification(currentOS: currentOS) { TextReplacementSync.saveState(state) }
        return state
    }

    /// force は待ち時間を省くが、試験済みの印と録音・会議・画面の条件は守る。
    func tick(busy: @escaping () -> Bool, force: Bool = false) {
        let state = currentState()
        let action = force
            ? (state.isVerified(currentOS: currentOS) ? TextReplacementSync.Action.sync : .liveTest)
            : TextReplacementSync.nextAction(now: Date(), state: state, currentOS: currentOS,
                                            idleSeconds: Self.idleSeconds, busy: busy(),
                                            screenAvailable: TextReplacementSync.screenAvailable)
        guard action != .none else { return }
        enqueue(action: action, busy: busy, force: force)
    }

    private func enqueue(action: TextReplacementSync.Action, busy: @escaping () -> Bool, force: Bool = false) {
        guard TextReplacementSync.screenAvailable, !busy() else { return }
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        queue.async {
            defer { self.lock.lock(); self.running = false; self.lock.unlock() }
            if force { Thread.sleep(forTimeInterval: 2) } // メニューを閉じる手の動きを待つ
            guard TextReplacementSync.screenAvailable, !busy() else { return }
            let state = self.currentState()
            switch action {
            case .none: break
            case .liveTest: self.performLiveTest(state: state)
            case .sync:
                if state.isVerified(currentOS: self.currentOS) { self.syncNow(state: state) }
                else { self.performLiveTest(state: state) }
            }
        }
    }

    private func syncNow(state initial: TextReplacementSync.State) {
        var state = initial
        // 呼び出し元の判定にかかわらず、印が無ければ本番は動かさない。
        if state.invalidateVerification(currentOS: currentOS) { TextReplacementSync.saveState(state) }
        guard state.isVerified(currentOS: currentOS) else { return }
        var todo: [TextReplacementSync.Pair] = []
        func recordAddedPairs() {
            guard let existing = try? TextReplacementSync.existing() else { return }
            let added = todo.filter { existing.contains($0) }
            for pair in added where !state.added.contains(pair) { state.added.append(pair) }
        }
        do {
            let dictionary = TermDictionary.loadForDictation()
            let candidates = TextReplacementSync.candidates(manual: dictionary.manual, learned: dictionary.learned,
                                                            excludedNames: TextReplacementSync.excludedNames())
            TextReplacementSync.writeExport(candidates)
            todo = Array(TextReplacementSync.plan(candidates, existing: try TextReplacementSync.existing()).prefix(TextReplacementSync.maxPerRun))
            if !todo.isEmpty {
                Log.write("ユーザ辞書へ取り込み開始: \(todo.count)件（\(todo.map(\.phrase).joined(separator: "・"))）")
                try TextReplacementUI().run(add: todo)
                state.added += todo
            }
            let missing = TextReplacementSync.plan(todo, existing: try TextReplacementSync.existing())
            guard missing.isEmpty else { throw TextReplacementSync.UIError.notAdded(missing[0].phrase) }
            state.lastSuccess = Date(); state.lastFailure = nil; state.lastError = nil
            TextReplacementSync.saveState(state)
            Log.write("ユーザ辞書へ取り込み: 成功（足した\(todo.count)件・写す語\(candidates.count)件）")
            DispatchQueue.main.async { self.onIssue?(nil) }
        } catch TextReplacementSync.UIError.interrupted {
            recordAddedPairs()
            TextReplacementSync.saveState(state)
            Log.write("ユーザ辞書へ取り込み: 画面が使えないか、キーボードかマウスが使われたので中断（次の機会にやり直す）")
        } catch {
            recordAddedPairs()
            let message = "ユーザ辞書への取り込みに失敗しました。" + error.localizedDescription
            state.lastFailure = Date(); state.lastError = message
            TextReplacementSync.saveState(state)
            Log.write(message)
            DispatchQueue.main.async { self.onIssue?(message) }
        }
    }

    /// 分散通知からの受け口。自動試験と同じ処理を使う。
    func liveTest(busy: @escaping () -> Bool) {
        enqueue(action: .liveTest, busy: busy)
    }

    /// 試験の語だけを足して確かめ、外す。前回の残りがあれば先に外す。
    private func performLiveTest(state initial: TextReplacementSync.State) {
        var state = initial
        state.verifiedAt = nil; state.verifiedOS = nil
        TextReplacementSync.saveState(state)
        let pair = TextReplacementSync.testPair
        do {
            let existing = try TextReplacementSync.existing()
            if existing.contains(pair) { try TextReplacementUI().run(add: [], remove: [pair]) }
            // 別の語と読み・語句が衝突する場合は、その語を消したり重ねたりしない。
            guard try !TextReplacementSync.plan([pair], existing: TextReplacementSync.existing()).isEmpty
            else { throw TextReplacementSync.UIError.notAdded(pair.phrase) }
            try TextReplacementUI().run(add: [pair], remove: [pair])
            guard try !TextReplacementSync.existing().contains(pair)
            else { throw TextReplacementSync.UIError.notRemoved(pair.phrase) }
            state.verifiedAt = Date(); state.verifiedOS = currentOS
            state.testFailures = 0; state.lastTestFailure = nil; state.lastError = nil
            TextReplacementSync.saveState(state)
            Log.write("ユーザ辞書の実機試験: 成功（足して確かめ、外した）")
            DispatchQueue.main.async { self.onIssue?(nil) }
        } catch TextReplacementSync.UIError.interrupted {
            // 中断では回数も最終失敗日時も変えない。残った試験語は次の試験で外す。
            let stillThere = (try? TextReplacementSync.existing().contains(pair)) == true
            Log.write("ユーザ辞書の実機試験: 中断（画面が使えないか、キーボードかマウスが使われた）" + (stillThere ? "（試験の語が残っています）" : ""))
            if stillThere {
                let message = "ユーザ辞書の実機試験を中断しました。試験の語が残っています。次の試験で外します。"
                state.lastError = message
                TextReplacementSync.saveState(state)
                DispatchQueue.main.async { self.onIssue?(message) }
            }
        } catch {
            let stillThere = (try? TextReplacementSync.existing().contains(pair)) == true
            let message = "ユーザ辞書の実機試験に失敗しました。" + error.localizedDescription
                + (stillThere ? "（試験の語が残っています）" : "")
            state.testFailures += 1; state.lastTestFailure = Date(); state.lastError = message
            TextReplacementSync.saveState(state)
            Log.write(message)
            DispatchQueue.main.async { self.onIssue?(message) }
        }
    }
}
