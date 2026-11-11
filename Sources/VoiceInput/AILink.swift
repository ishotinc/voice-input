import AppKit

/// 連携を戻すために押すもの。
enum AILinkFix: Equatable {
    case login(tool: String, executable: String, arguments: [String])
    case key(AIProvider)
}

enum AILinkStatus: Equatable {
    case unknown, connected
    /// ログインかキーの設定で直る。メニューバーに「!」を出す。
    case down(AILinkFix)
    /// ログインでは直らない（利用上限・CLI が無いなど）。説明だけ出す。
    case blocked(String, fromPolish: Bool)

    var fix: AILinkFix? { if case .down(let fix) = self { return fix }; return nil }
    var blockedMessage: String? { if case .blocked(let message, _) = self { return message }; return nil }
}

/// 確認の結果から今の状態を決める。一時的な失敗では状態を変えない。
struct AILinkTracker {
    private(set) var provider: AIProvider?
    private(set) var status = AILinkStatus.unknown
    /// `auth status` は通るのに本番の補正がログイン切れだった形（2026-11-06）。軽い確認だけでは解消を判断できない。
    private(set) var awaitingRealResponse = false

    private enum Verdict { case unchanged, down(AILinkFix), blocked(String) }

    private static func verdict(_ error: Error, provider: AIProvider) -> Verdict {
        switch PolishRecovery.kind(of: error) {
        case .cancelled, .transient: return .unchanged
        case .login, .stop:
            switch AIConnection.outcome(for: error, provider: provider) {
            case .needsLogin(let tool, let executable, let arguments): return .down(.login(tool: tool, executable: executable, arguments: arguments))
            case .needsKey(let keyProvider): return .down(.key(keyProvider))
            case .failed(let reason): return .blocked(reason)
            case .connected: return .unchanged
            }
        }
    }

    mutating func adopt(_ provider: AIProvider?) {
        guard provider != self.provider else { return }
        self.provider = provider
        status = .unknown
        awaitingRealResponse = false
    }

    /// 補正を呼ばない確認の結果。
    mutating func observeLight(_ error: Error?, provider: AIProvider) {
        guard provider == self.provider else { return }
        guard let error else {
            if awaitingRealResponse, status.fix != nil { return }
            if case .blocked(_, fromPolish: true) = status { return }
            status = .connected
            return
        }
        switch Self.verdict(error, provider: provider) {
        case .unchanged: break
        case .down(let fix): status = .down(fix); awaitingRealResponse = false
        case .blocked(let message): status = .blocked(message, fromPolish: false); awaitingRealResponse = false
        }
    }

    /// 実際の補正の結果。
    mutating func observePolish(_ error: Error?, provider: AIProvider) {
        guard provider == self.provider else { return }
        guard let error else { status = .connected; awaitingRealResponse = false; return }
        switch Self.verdict(error, provider: provider) {
        case .unchanged: break
        case .down(let fix): status = .down(fix); awaitingRealResponse = true
        case .blocked(let message): status = .blocked(message, fromPolish: true); awaitingRealResponse = false
        }
    }

    /// 実際の応答まで見た確認の結果（再接続と、軽い確認で判断できないときの確認）。
    mutating func observeProbe(_ error: Error?, provider: AIProvider) {
        guard provider == self.provider else { return }
        guard let error else { status = .connected; awaitingRealResponse = false; return }
        switch Self.verdict(error, provider: provider) {
        case .unchanged: break
        case .down(let fix): status = .down(fix)
        case .blocked(let message): status = .blocked(message, fromPolish: false); awaitingRealResponse = false
        }
    }

    /// 利用上限などの知らせは次の録音で確かめ直す。
    mutating func clearPolishBlock() {
        if case .blocked(_, fromPolish: true) = status { status = .unknown }
    }

    /// キーを入れ直したら、前の 401 を引きずらない。
    mutating func keyChanged() { awaitingRealResponse = false }

    /// ログインで直る形で、軽い確認では解消が分からないときだけ true。
    var needsRealResponseCheck: Bool {
        guard awaitingRealResponse, case .login = status.fix else { return false }
        return true
    }
}

/// 連携切れを先に見つける。主スレッドから使い、確認そのものは裏で走らせる。
final class AILinkMonitor {
    static let normalInterval: TimeInterval = 300
    static let downInterval: TimeInterval = 30
    /// 切れているあいだは補正が失敗するので利用枠を使わない。通った1回だけ短い文の分を使う。
    static let probeInterval: TimeInterval = 120
    static let probeIntervalAfterLogin: TimeInterval = 30
    static let loginWatchWindow: TimeInterval = 600
    private static let tickInterval: TimeInterval = 10
    private static let wakeDelay: TimeInterval = 5

    private(set) var tracker = AILinkTracker()
    var status: AILinkStatus { tracker.status }
    var onChange: ((AILinkStatus, AILinkStatus) -> Void)?

    private let activeProvider: () -> AIProvider?
    private let light: (AIProvider) throws -> Void
    private let probe: (AIProvider) throws -> Void
    private let clock: () -> TimeInterval
    private let inline: Bool
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var running = false
    private var rerun = false
    private var lastCheck: TimeInterval?
    private var lastProbe: TimeInterval?
    private var loginOpenedAt: TimeInterval?

    /// inline は試験用。確認を呼び出しの中で終わらせる。
    init(activeProvider: @escaping () -> AIProvider?,
         light: @escaping (AIProvider) throws -> Void = { try Polisher.lightAuthenticationCheck($0) },
         probe: @escaping (AIProvider) throws -> Void = { try AIConnection.defaultProbe($0) },
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         inline: Bool = false) {
        self.activeProvider = activeProvider
        self.light = light
        self.probe = probe
        self.clock = clock
        self.inline = inline
    }

    deinit {
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in self?.tick() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeDelay) { self?.checkNow() }
        }
        checkNow()
    }

    var isDue: Bool {
        guard let lastCheck else { return true }
        return clock() - lastCheck >= (status.fix != nil ? Self.downInterval : Self.normalInterval)
    }

    func tick() { if isDue { checkNow() } }

    /// 録音開始のように続けて呼ばれる場所用。直前に確かめたばかりなら省く。
    func checkIfStale(olderThan seconds: TimeInterval) {
        if let lastCheck, clock() - lastCheck < seconds { return }
        checkNow()
    }

    func checkNow() {
        guard let provider = activeProvider() else { mutate { $0.adopt(nil) }; return }
        mutate { $0.adopt(provider) }
        if running { rerun = true; return }
        running = true
        lastCheck = clock()
        background {
            let failure = self.capture { try self.light(provider) }
            self.foreground {
                self.mutate { $0.observeLight(failure, provider: provider) }
                self.probeIfDue(provider)
            }
        }
    }

    private var probeIsDue: Bool {
        guard let lastProbe else { return true }
        let watching = loginOpenedAt.map { clock() - $0 < Self.loginWatchWindow } ?? false
        return clock() - lastProbe >= (watching ? Self.probeIntervalAfterLogin : Self.probeInterval)
    }

    private func probeIfDue(_ provider: AIProvider) {
        guard tracker.needsRealResponseCheck, tracker.provider == provider, probeIsDue else { finishCheck(); return }
        lastProbe = clock()
        background {
            let failure = self.capture { try self.probe(provider) }
            self.foreground {
                self.mutate { $0.observeProbe(failure, provider: provider) }
                self.finishCheck()
            }
        }
    }

    private func finishCheck() {
        running = false
        if rerun { rerun = false; checkNow() }
    }

    func reportPolish(_ error: Error?, provider: AIProvider) {
        guard activeProvider() == provider else { return }
        mutate { $0.adopt(provider); $0.observePolish(error, provider: provider) }
        // 軽い確認でも切れているなら、ログインのあとは軽い確認だけで解消できる。その見分けのため確かめ直す。
        if error != nil, status.fix != nil { checkNow() }
    }

    func reportReconnect(_ outcome: AIConnection.Outcome, provider: AIProvider) {
        guard activeProvider() == provider else { return }
        mutate { tracker in
            tracker.adopt(provider)
            switch outcome {
            case .connected: tracker.observeProbe(nil, provider: provider)
            case .needsLogin(let name, _, _):
                tracker.observeProbe(name == "Codex" ? Polisher.PolishError.codexLoginRequired : Polisher.PolishError.maxLoginRequired, provider: provider)
            case .needsKey(let keyProvider):
                tracker.observeProbe(keyProvider == .claude ? Polisher.PolishError.cliMissing : Polisher.PolishError.openAIKeyMissing, provider: provider)
            case .failed: break
            }
        }
    }

    func clearPolishBlock() { mutate { $0.clearPolishBlock() } }
    func noteLoginOpened() { loginOpenedAt = clock() }
    func noteKeyChanged() { mutate { $0.keyChanged() }; checkNow() }

    private func mutate(_ change: (inout AILinkTracker) -> Void) {
        let old = tracker.status
        change(&tracker)
        guard tracker.status != old else { return }
        // 覚えている「確認済み」を捨て、次の補正は認証を確かめ直す。
        if let provider = tracker.provider { Polisher.resetAuthentication(provider) }
        onChange?(old, tracker.status)
    }

    private func capture(_ body: () throws -> Void) -> Error? {
        do { try body(); return nil } catch { return error }
    }

    private func background(_ body: @escaping () -> Void) {
        if inline { body() } else { DispatchQueue.global(qos: .utility).async(execute: body) }
    }

    private func foreground(_ body: @escaping () -> Void) {
        if inline { body() } else { DispatchQueue.main.async(execute: body) }
    }
}

/// 連携切れのアイコン。色を固定して描くので、メニューバーが明るくても暗くても見える。
enum AILinkIcon {
    static let description = "AIとの連携が切れています"

    static func image() -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed]))
        let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }

    /// 見た目の確認用。白地と黒地に並べて PNG へ書き出す。画面は撮らない。
    static func renderSample(to url: URL) -> Bool {
        guard let image = image(),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 120, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for (x, color) in [(CGFloat(0), NSColor.white), (120, NSColor.black)] {
            color.setFill()
            NSRect(x: x, y: 0, width: 120, height: 120).fill()
            let size = image.size
            let scale = 64 / max(size.width, size.height)
            let box = NSSize(width: size.width * scale, height: size.height * scale)
            image.draw(in: NSRect(x: x + (120 - box.width) / 2, y: (120 - box.height) / 2, width: box.width, height: box.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
