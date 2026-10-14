import Foundation

/// ファイルの置き場所を1か所にまとめる。ここ以外でパスを組み立てない。
enum Paths {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".voice-input", isDirectory: true)

    static var models: URL { root.appendingPathComponent("models", isDirectory: true) }
    static var tmp: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    static var terms: URL { root.appendingPathComponent("terms.json") }
    static var settings: URL { root.appendingPathComponent("settings.json") }
    static var log: URL { root.appendingPathComponent("voice-input.log") }

    /// 初回起動時に ~/.voice-input を作り、アプリ同梱の terms.json を置く。
    static func bootstrap() {
        let fm = FileManager.default
        for dir in [root, models, tmp] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: terms.path), let bundled = bundledTerms() {
            try? fm.copyItem(at: bundled, to: terms)
        }
        // 前回落ちたときに残った音声を掃除する（長期保存しない）
        if let leftovers = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for f in leftovers { try? fm.removeItem(at: f) }
        }
    }

    /// 同梱の terms.json。.app からでも `swift run` からでも見つける。
    static func bundledTerms() -> URL? {
        let fm = FileManager.default
        if let inBundle = Bundle.main.url(forResource: "terms", withExtension: "json") {
            return inBundle
        }
        // 実行ファイルの上に向かって Resources/terms.json を探す。
        // .app（Contents/MacOS → Contents/Resources）でも .build/... でも同じ探し方で当たる。
        var starts: [URL] = []
        if let exe = Bundle.main.executableURL {
            starts.append(exe.resolvingSymlinksInPath().deletingLastPathComponent())
        }
        let argv0 = CommandLine.arguments.first ?? ""
        if argv0.contains("/") {
            starts.append(URL(fileURLWithPath: argv0, relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath))
                .resolvingSymlinksInPath().deletingLastPathComponent())
        }
        for start in starts {
            var dir = start
            for _ in 0..<6 {
                let candidate = dir.appendingPathComponent("Resources/terms.json")
                if fm.fileExists(atPath: candidate.path) { return candidate }
                dir = dir.deletingLastPathComponent()
            }
        }
        return nil
    }

    /// 既定のモデル。設定で上書きできる。
    static var defaultModel: URL { models.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin") }

    /// whisper-cli の探索順。Homebrew と自前ビルドの両方を見る。
    static let whisperCandidates = [
        "/opt/homebrew/bin/whisper-cli",
        "/usr/local/bin/whisper-cli",
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".voice-input/bin/whisper-cli").path,
    ]
}
