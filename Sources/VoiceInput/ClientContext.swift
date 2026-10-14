import Foundation
import Darwin

/// Selected Markdown only; content is reloaded for each recording and never cached on disk.
struct ClientContext {
    let referenceText: String
    let fileCount: Int
    let truncated: Bool
    let unavailable: Bool

    var status: String {
        if unavailable { return "顧客資料: 読み取り不可（通常変換）" }
        if fileCount == 0 { return truncated ? "顧客資料: 探索上限内に読めるMarkdownがありません" : "顧客資料: 読めるMarkdownがありません" }
        return "顧客資料: \(fileCount)件" + (truncated ? "（上限のため一部のみ）" : "")
    }

    var vocabulary: [String] {
        ScreenContext(appName: "", windowTitle: "", focusedText: referenceText).vocabulary
    }

    /// Aliases are scoped to the selected folder and used as hints, never substring replacements.
    func validatedAliases(_ aliases: [String: String]) -> [String: String] {
        aliases.filter { reading, name in
            !reading.isEmpty && reading.count <= 80 && !name.isEmpty && name.count <= 80
                && !reading.contains("\n") && !name.contains("\n") && referenceText.contains(name)
        }
    }

    func initialPrompt(dictionary: String, screen: ScreenContext?, aliases: [String: String] = [:]) -> String {
        let names = validatedAliases(aliases).values.sorted()
        let hints = (names + vocabulary + (screen?.vocabulary ?? [])).joined(separator: "、")
        return String(dictionary.prefix(200)) + "\n参考表記: " + String(hints.prefix(150))
    }

    static func load(folderPath: String, maxFiles: Int = 10, maxCharacters: Int = 12000, maxBytes: Int = 200000, perFileBytes: Int = 32000, timeBudget: TimeInterval = 0.6) -> ClientContext {
        let empty = ClientContext(referenceText: "", fileCount: 0, truncated: false, unavailable: true)
        guard !folderPath.isEmpty else { return empty }
        let fm = FileManager.default
        func canonicalPath(_ path: String) -> String? {
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        guard let selectedPath = canonicalPath(folderPath) else { return empty }
        let selected = URL(fileURLWithPath: selectedPath)
        let isFile = (try? selected.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        if isFile && !["md", "markdown"].contains(selected.pathExtension.lowercased()) { return empty }
        let rootPath = isFile ? selected.deletingLastPathComponent().path : selectedPath
        let root = URL(fileURLWithPath: rootPath)
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return empty }
        let deadline = Date().addingTimeInterval(timeBudget)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var candidates: [(URL, Date, Int)] = isFile ? [(selected, .distantPast, 0)] : []
        var directories = isFile ? [] : [root]
        var visited = 0
        var truncated = false
        while !directories.isEmpty {
            if visited >= 400 || Date() > deadline { truncated = true; break }
            let directory = directories.removeFirst()
            guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for url in entries.sorted(by: { $0.path < $1.path }) {
                visited += 1
                if visited > 400 || Date() > deadline { truncated = true; break }
                guard let info = try? url.resourceValues(forKeys: Set(keys)), info.isSymbolicLink != true else { continue }
                guard canonicalPath(url.path) == url.path, url.path.hasPrefix(rootPath + "/") else { continue }
                if info.isDirectory == true { directories.append(url); continue }
                guard info.isRegularFile == true, ["md", "markdown"].contains(url.pathExtension.lowercased()) else { continue }
                if isFile && url.path != selectedPath { continue }
                let relative = String(url.path.dropFirst(rootPath.count + 1))
                let rank = (!relative.contains("/") || url.deletingPathExtension().lastPathComponent == url.deletingLastPathComponent().lastPathComponent) ? 0 : (relative.lowercased().contains("meeting") || relative.contains("議事録") ? 1 : 2)
                candidates.append((url, info.contentModificationDate ?? .distantPast, rank))
            }
        }
        candidates.sort { a, b in a.2 != b.2 ? a.2 < b.2 : (a.1 != b.1 ? a.1 > b.1 : a.0.path < b.0.path) }
        var text = "", count = 0, bytesRead = 0
        for (url, _, _) in candidates {
            if count >= maxFiles || text.count >= maxCharacters || bytesRead >= maxBytes || Date() > deadline { truncated = true; break }
            guard canonicalPath(url.path) == url.path, url.path.hasPrefix(rootPath + "/") else { continue }
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var statInfo = stat()
            guard fstat(fd, &statInfo) == 0, (statInfo.st_mode & S_IFMT) == S_IFREG else { continue }
            let limit = min(perFileBytes, maxBytes - bytesRead)
            guard let data = try? handle.read(upToCount: limit), !data.isEmpty else { continue }
            bytesRead += data.count
            if statInfo.st_size > limit { truncated = true }
            let content = String(decoding: data, as: UTF8.self)
            let remaining = maxCharacters - text.count
            let section = "\n--- " + String(url.path.dropFirst(rootPath.count + 1).prefix(240)) + " ---\n" + content
            if section.count > remaining { truncated = true }
            text += String(section.prefix(remaining))
            count += 1
        }
        return ClientContext(referenceText: text, fileCount: count, truncated: truncated, unavailable: false)
    }
}
