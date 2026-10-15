import AppKit
import ApplicationServices

/// One recording's bounded accessibility text, held only in memory.
struct ScreenContext {
    let appName: String
    let windowTitle: String
    let focusedText: String

    var referenceText: String {
        String("App: \(appName)\nWindow: \(windowTitle)\nNearby text: \(focusedText)".prefix(6500))
    }

    /// Extract word-shaped spelling hints only, never full screen sentences/instructions.
    var vocabulary: [String] {
        let pattern = #"[A-Za-z][A-Za-z0-9_-]{2,39}|[ァ-ヶー]{2,20}|[一-龯]{2,10}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let vocabularyText = appName + " " + windowTitle + " " + focusedText
        let source = vocabularyText as NSString
        var seen = Set<String>()
        return regex.matches(in: vocabularyText, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range) }
            .filter { seen.insert($0).inserted }
            .prefix(32).map { $0 }
    }

    func initialPrompt(dictionary: String) -> String {
        let hints = vocabulary.joined(separator: "、")
        return String(dictionary.prefix(240)) + (hints.isEmpty ? "" : "\n参考表記: " + String(hints.prefix(110)))
    }

    static func capture(app: NSRunningApplication?, allowOwnProcess: Bool = false) -> ScreenContext? {
        func unavailable(_ reason: String) -> ScreenContext? {
            Log.write("画面参照不可: \(reason) app=\(app?.bundleIdentifier ?? "unknown")")
            return nil
        }
        guard AXIsProcessTrusted() else { return unavailable("アクセシビリティ未許可") }
        guard let app, (allowOwnProcess || app.processIdentifier != ProcessInfo.processInfo.processIdentifier) else { return unavailable("対象アプリなし・自アプリ") }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let deadline = Date().addingTimeInterval(1.5)
        AXUIElementSetMessagingTimeout(application, 0.1)
        // Electron/Chromium expose their text tree only after an accessibility client requests it.
        // This enables the target's tree, not macOS permissions; never show a permission prompt.
        for attribute in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            var settable = DarwinBoolean(false)
            let supported = AXUIElementIsAttributeSettable(application, attribute as CFString, &settable) == .success && settable.boolValue
            let chromium = app.bundleIdentifier?.hasPrefix("com.google.Chrome") == true
                || app.bundleURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) } == true
            if supported || chromium {
                let status = AXUIElementSetAttributeValue(application, attribute as CFString, kCFBooleanTrue)
                Log.write("画面参照 AX公開要求 \(attribute)=\(status.rawValue)")
            }
        }
        var lastAXError: AXError = .success
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard Date() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.1)
            var result: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
            guard error == .success else { lastAXError = error; return nil }
            return result
        }
        func element(_ owner: AXUIElement, _ attribute: String) -> AXUIElement? {
            guard let object = value(owner, attribute), CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            return (object as! AXUIElement)
        }
        func focusedElement() -> AXUIElement? {
            if let local = element(application, kAXFocusedUIElementAttribute) { return local }
            // Some applications expose focus only through the system-wide accessibility object.
            if let systemFocus = element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) {
                var pid: pid_t = 0
                if AXUIElementGetPid(systemFocus, &pid) == .success, pid == app.processIdentifier { return systemFocus }
            }
            return nil
        }
        var focus = focusedElement()
        for _ in 0..<3 where focus == nil && Date() < deadline {
            guard allowOwnProcess || NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return unavailable("取得中に対象が変化") }
            Thread.sleep(forTimeInterval: 0.05)
            focus = focusedElement()
        }
        guard let focused = focus else { return unavailable("フォーカス取得失敗 AX=\(lastAXError.rawValue)") }
        // Fail closed when the focused field cannot be classified; check its ancestors too.
        guard value(focused, kAXRoleAttribute) as? String != nil else { return unavailable("入力欄の種類を判別できない") }
        Log.write("画面参照 focus role=\(value(focused, kAXRoleAttribute) as? String ?? "unknown") subrole=\(value(focused, kAXSubroleAttribute) as? String ?? "none")")
        var ancestor: AXUIElement? = focused
        for _ in 0..<6 {
            guard let current = ancestor else { break }
            if (value(current, kAXSubroleAttribute) as? String) == "AXSecureTextField" { return unavailable("パスワード欄を除外") }
            ancestor = element(current, kAXParentAttribute)
        }
        let window = element(application, kAXFocusedWindowAttribute)
        let title = window.flatMap { value($0, kAXTitleAttribute) as? String } ?? ""
        // Prefer selection; avoid traversing the whole screen or unrelated windows.
        let selected = value(focused, kAXSelectedTextAttribute) as? String ?? ""
        let text = selected.isEmpty ? (value(focused, kAXValueAttribute) as? String ?? "") : selected
        var nearby = ""
        var queue = element(focused, kAXParentAttribute).map { [$0] } ?? window.map { [$0] } ?? []
        if let window { queue.append(window) }
        var seenLabels = Set<String>()
        var seenNodes: [AXUIElement] = []
        var visited = 0
        while !queue.isEmpty && visited < 240 && nearby.count < 4800 && Date() < deadline {
            let node = queue.removeFirst()
            if seenNodes.contains(where: { CFEqual($0, node) }) { continue }
            seenNodes.append(node)
            visited += 1
            if (value(node, kAXSubroleAttribute) as? String) == "AXSecureTextField" {
                if value(node, kAXFocusedAttribute) as? Bool == true { return unavailable("パスワード欄を除外") }
                continue
            }
            if (value(node, kAXRoleAttribute) as? String) == kAXStaticTextRole,
               let label = value(node, kAXValueAttribute) as? String, !label.isEmpty, seenLabels.insert(label).inserted {
                nearby += String(label.prefix(1000)) + "\n"
            }
            if let children = value(node, kAXVisibleChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(max(0, 240 - visited - queue.count)))
            } else if let children = value(node, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(max(0, 240 - visited - queue.count)))
            }
        }
        return ScreenContext(appName: String((app.localizedName ?? "").prefix(100)),
                             windowTitle: String(title.prefix(300)), focusedText: String(text.suffix(1200)) + "\n" + String(nearby.prefix(4800)))
    }
}

/// One bounded capture running alongside audio; never persisted.
final class ScreenPreparation {
    private let group = DispatchGroup()
    private var result: ScreenContext?
    init(app: NSRunningApplication?) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            self.result = ScreenContext.capture(app: app)
            Log.write("画面参照: \(self.result?.focusedText.count ?? 0)文字取得（本文非保存）")
            self.group.leave()
        }
    }
    func wait() -> ScreenContext? { group.wait(); return result }
}
