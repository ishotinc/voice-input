import AppKit
import AVFoundation
import IOKit.hid

/// 3つの権限の状態を名指しで出す。足りないまま黙って進めない。
enum Permission: CaseIterable {
    case microphone
    case accessibility
    case inputMonitoring

    var title: String {
        switch self {
        case .microphone: return "マイク"
        case .accessibility: return "アクセシビリティ"
        case .inputMonitoring: return "入力監視"
        }
    }

    var reason: String {
        switch self {
        case .microphone: return "録音するため（必須）"
        case .accessibility: return "⌘V を送って貼り付けるため（必須）"
        case .inputMonitoring: return "不要。⌥Space は Carbon で届くので、一覧に出てこなくて問題ありません"
        }
    }

    /// 設定画面を開くボタンを出すか。入力監視は一覧に候補として出ないので、押しても何も無い。
    var showsSettingsButton: Bool { self != .inputMonitoring }

    var isRequired: Bool { self != .inputMonitoring }

    var settingsURL: URL {
        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    var isGranted: Bool {
        switch self {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility:
            return AXIsProcessTrusted()
        case .inputMonitoring:
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        }
    }
}

enum Permissions {
    /// 足りない権限（必須のみ）。
    static var missingRequired: [Permission] {
        Permission.allCases.filter { $0.isRequired && !$0.isGranted }
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        default:
            completion(false)
        }
    }

    /// システムの要求ダイアログは出さず、ユーザーが選んだ設定だけ開く。
    static func open(_ permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }
}
