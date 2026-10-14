import Foundation

/// 何が起きたかを後から追えるようにする。GUIアプリは標準出力が見えないため必ずファイルに残す。
enum Log {
    private static let queue = DispatchQueue(label: "com.ishot.voice-input.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: Paths.log) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: Paths.log)
            }
        }
    }

    /// ログが太り続けないように、起動時に 200KB を超えていたら切り詰める。
    static func rotateIfNeeded() {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: Paths.log.path)[.size] as? Int, size > 200_000 else { return }
        guard let text = try? String(contentsOf: Paths.log, encoding: .utf8) else { return }
        let tail = text.suffix(50_000)
        try? String(tail).write(to: Paths.log, atomically: true, encoding: .utf8)
    }
}
