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
        guard AXIsProcessTrusted(), let app, (allowOwnProcess || app.processIdentifier != ProcessInfo.processInfo.processIdentifier) else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let deadline = Date().addingTimeInterval(1.0)
        AXUIElementSetMessagingTimeout(application, 0.025)
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard Date() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.025)
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
            return result
        }
        func element(_ owner: AXUIElement, _ attribute: String) -> AXUIElement? {
            guard let object = value(owner, attribute), CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            return (object as! AXUIElement)
        }
        guard let focused = element(application, kAXFocusedUIElementAttribute) else { return nil }
        // Fail closed when the focused field cannot be classified; check its ancestors too.
        guard value(focused, kAXRoleAttribute) as? String != nil else { return nil }
        var ancestor: AXUIElement? = focused
        for _ in 0..<6 {
            guard let current = ancestor else { break }
            if (value(current, kAXSubroleAttribute) as? String) == "AXSecureTextField" { return nil }
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
        var visited = 0
        while !queue.isEmpty && visited < 240 && nearby.count < 4800 && Date() < deadline {
            let node = queue.removeFirst()
            visited += 1
            if (value(node, kAXSubroleAttribute) as? String) == "AXSecureTextField" { continue }
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
