import AppKit

/// Intercept only Option-right-click; leave every ordinary mouse event untouched.
final class HistoryShortcut {
    var onOpen: ((NSPoint, NSRunningApplication?) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var gesture: (NSPoint, NSRunningApplication?)?

    static func matches(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskAlternate)
            && flags.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty
    }

    @discardableResult func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<HistoryShortcut>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.gesture = nil
                if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if type == .rightMouseDown, HistoryShortcut.matches(event.flags) {
                owner.gesture = (NSEvent.mouseLocation, NSWorkspace.shared.frontmostApplication)
                return nil
            }
            if type == .rightMouseUp, let gesture = owner.gesture {
                owner.gesture = nil
                DispatchQueue.main.async { owner.onOpen?(gesture.0, gesture.1) }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask,
                                         callback: callback,
                                         userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.write("履歴ショートカット: 登録不可（アクセシビリティの許可を確認）")
            return false
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.write("⌥＋右クリック: 履歴ショートカットを登録")
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil; gesture = nil
    }
}
