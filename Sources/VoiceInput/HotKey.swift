import AppKit
import Carbon.HIToolbox

/// ⌥Space を Carbon の RegisterEventHotKey で登録する。
/// アプリが前面でなくても効き、アクセシビリティ権限がなくても登録できる。
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x69736876 // 'ishv'
    private let id: UInt32 = 1

    /// Carbon のコールバックは C 関数ポインタなので、呼び先をここに置く。
    fileprivate static var handlers: [UInt32: () -> Void] = [:]

    /// ⌥Space。キーコード 49 = Space。
    func register(keyCode: UInt32 = UInt32(kVK_Space),
                  modifiers: UInt32 = UInt32(optionKey),
                  action: @escaping () -> Void) -> Bool {
        HotKeyManager.handlers[id] = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(),
                                                voiceInputHotKeyCallback,
                                                1, &eventType, nil, &handlerRef)
        guard installStatus == noErr else {
            Log.write("ホットキーのハンドラ登録に失敗: \(installStatus)")
            return false
        }

        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            Log.write("⌥Space の登録に失敗: \(status)（他のアプリが同じキーを取っている可能性）")
            return false
        }
        Log.write("⌥Space を登録した")
        return true
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let ref = handlerRef { RemoveEventHandler(ref); handlerRef = nil }
        HotKeyManager.handlers.removeValue(forKey: id)
    }

    deinit { unregister() }
}

private func voiceInputHotKeyCallback(_ next: EventHandlerCallRef?,
                                      _ event: EventRef?,
                                      _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hkID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hkID)
    guard status == noErr else { return status }
    if let action = HotKeyManager.handlers[hkID.id] {
        DispatchQueue.main.async { action() }
    }
    return noErr
}
