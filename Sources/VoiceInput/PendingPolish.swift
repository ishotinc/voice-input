import Foundation
import Darwin

/// AI 補正に失敗して、まだやり直しも貼り付けもしていない文章。解決するまでディスクに残す。
/// 画面の内容は保存しない。顧客資料は場所だけ持ち、やり直すときに読み直す。
struct PendingPolish: Codable, Equatable {
    let id: String
    let createdAt: Date
    let text: String
    let styleWarnings: [String]
    let targetBundleID: String?
    let recordingName: String?
    let keepAudio: Bool
    let clientFolder: String

    /// 再起動をまたいだ文章を、今の設定でやり直すための材料。
    func restoredJob(settings: Settings) -> PolishJob {
        let client = clientFolder.isEmpty ? nil : ReferencePreparation(folder: clientFolder).wait()
        return PolishJob(text: text, model: settings.polishModel, effort: settings.polishEffort, context: nil, client: client,
                         aliases: settings.clientNameAliases[clientFolder] ?? [:], instructions: settings.customPolishInstructions,
                         jevSettings: settings.jev)
    }
}

/// `recovery/unpolished-<id>.json` を 0600 で読み書きする。本文はログに書かない。
struct PendingPolishStore {
    enum Failure: LocalizedError {
        case system(String, Int32)
        var errorDescription: String? {
            if case .system(let step, let code) = self { return "\(step)に失敗（errno \(code)）" }
            return nil
        }
    }

    private static let prefix = "unpolished-"
    private static let suffix = ".json"
    let folder: URL

    private func url(id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return folder.appendingPathComponent(Self.prefix + id + Self.suffix)
    }

    /// 同じ id は置き換える。一時ファイルも最初から 0600 で作る。
    func save(_ item: PendingPolish) throws {
        guard let destination = url(id: item.id) else { throw Failure.system("id の確認", EINVAL) }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let data = try JSONEncoder().encode(item)
        let temporary = folder.appendingPathComponent(".pending-" + UUID().uuidString + ".tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw Failure.system("作成", errno) }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, destination.path) == 0 else { throw Failure.system("書き込み", errno) }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    /// 新しいものから順に返す。読めないファイルは消さずに飛ばす。
    func loadAll() -> [PendingPolish] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { $0.hasPrefix(Self.prefix) && $0.hasSuffix(Self.suffix) }.compactMap { name -> PendingPolish? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let item = try? JSONDecoder().decode(PendingPolish.self, from: data), url(id: item.id)?.lastPathComponent == name else {
                Log.write("未解決の文章を読めないので飛ばした: " + name)
                return nil
            }
            return item
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func remove(id: String) {
        guard let target = url(id: id) else { return }
        try? FileManager.default.removeItem(at: target)
    }
}
