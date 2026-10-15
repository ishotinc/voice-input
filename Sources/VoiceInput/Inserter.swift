import AppKit
import Carbon.HIToolbox

/// クリップボード経由で ⌘V を送って貼り付ける。1文字ずつ送る方法は日本語の変換で崩れる。
/// Enter は絶対に送らない。送信するかどうかは人が決める。
enum Inserter {

    /// デバッグ用。true にすると、アクセシビリティがあっても予備経路（System Events）を通る。
    static var forceSystemEventsPath = false

    /// 貼り付け前のクリップボードを丸ごと控える。
    private struct Snapshot {
        var items: [[String: Data]]
        var changeCount: Int
    }

    private static func snapshot() -> Snapshot {
        let pb = NSPasteboard.general
        var items: [[String: Data]] = []
        for item in pb.pasteboardItems ?? [] {
            var payload: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { payload[type.rawValue] = data }
            }
            if !payload.isEmpty { items.append(payload) }
        }
        return Snapshot(items: items, changeCount: pb.changeCount)
    }

    private static func restore(_ snap: Snapshot, ourChangeCount: Int) {
        let pb = NSPasteboard.general
        // 貼り付け後にユーザーが別のものをコピーしていたら、そちらを壊さない
        guard pb.changeCount == ourChangeCount else {
            Log.write("クリップボードが書き換わっていたので復元しない")
            return
        }
        pb.clearContents()
        guard !snap.items.isEmpty else { return }
        let restored: [NSPasteboardItem] = snap.items.map { payload in
            let item = NSPasteboardItem()
            for (type, data) in payload {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pb.writeObjects(restored)
    }

    enum InsertError: LocalizedError {
        /// 貼れなかったが、クリップボードには入れてある。
        case noAccessibility
        var errorDescription: String? {
            "クリップボードに入れました。⌘V で貼り付けてください（自動で貼るには、アクセシビリティかオートメーションの許可が要ります）。"
        }
    }

    /// - Parameters:
    ///   - text: 貼るテキスト。末尾に改行は付けない（改行が送信になる場面があるため）。
    ///   - target: 録音を始めた時点で最前面だったアプリ。切り替わっていたら戻してから貼る。
    ///   - completion: 主スレッドで呼ぶ。nil なら貼れた。エラーならクリップボードに残してある。
    ///
    /// 許可済みならCGEventで貼り付け、未許可ならクリップボードに残す。
    static func insert(_ text: String,
                       into target: NSRunningApplication?,
                       shouldPaste: @escaping () -> Bool = { true },
                       completion: @escaping (Error?) -> Void) {
        let body = text.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        guard !body.isEmpty else { completion(nil); return }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(body, forType: .string)

        guard shouldPaste() else { completion(nil); return }
        let clipboardVersion = pb.changeCount
        let needsSwitch = target != nil
            && NSWorkspace.shared.frontmostApplication?.processIdentifier != target?.processIdentifier
        if needsSwitch, let target, !target.isTerminated {
            target.activate()
            Log.write("貼り付け先を \(target.localizedName ?? "?") に戻した")
        }

        // 前面が入れ替わるのを待ってから ⌘V。切り替えが要らないときは短くする。
        let delay: TimeInterval = needsSwitch ? 0.30 : 0.06

        // CGEvent は主スレッドから投げる。別スレッドから投げると届かない（実測で貼り付けが空になった）。
        if AXIsProcessTrusted() && CGPreflightPostEventAccess() && !forceSystemEventsPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard shouldPaste(), pb.changeCount == clipboardVersion else { completion(nil); return }
                guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
                    completion(InsertError.noAccessibility)
                    return
                }
                sendCommandV()
                // Keep the transcript available for manual paste after auto-paste.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    completion(nil)
                }
            }
            return
        }

        // 権限不足時はOSの同意要求を発生させず、手動貼り付け用に残す。
        Log.write("自動で貼れないのでクリップボードに残した（\(body.count)文字）")
        completion(InsertError.noAccessibility)
    }

    /// ⌘V を送らずに、控え→書き換え→復元だけを確かめる。デバッグ用。
    static func testSnapshotRoundTrip(replacing text: String) -> Bool {
        let pb = NSPasteboard.general
        let before = pb.string(forType: .string)
        let snap = snapshot()
        pb.clearContents()
        pb.setString(text, forType: .string)
        let ours = pb.changeCount
        restore(snap, ourChangeCount: ours)
        return pb.string(forType: .string) == before
    }

    private static func sendCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            Log.write("CGEventSource を作れなかった")
            return
        }
        // 押しっぱなしの修飾キーを拾わないよう、⌘だけを明示する
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents], state: .eventSuppressionStateSuppressionInterval)

        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false) else {
            Log.write("キーイベントを作れなかった")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
