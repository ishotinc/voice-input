import AppKit
import CryptoKit
import Security
import Darwin
import UniformTypeIdentifiers

struct GoogleMeetingEntry {
    let speaker: String
    let text: String
    let start: Date
    let end: Date
}

/// Call network methods off the main thread. OAuth credentials live only in Keychain.
final class MeetingGoogleDrive {
    static let shared = MeetingGoogleDrive()
    struct Failure: LocalizedError { let message: String; var status: Int? = nil; var errorDescription: String? { message } }
    private struct Client: Codable { let client_id: String; let client_secret: String? }
    private struct Credentials: Codable { var client: Client; var refreshToken: String; var accountID: String }
    private struct StreamState: Codable { var key: String; var hash: String; var pendingHash: String? }
    private struct State: Codable {
        var transcriptStreams: [String: StreamState]?
        var accountID: String?
        var folderID: String?
        var documents: [String:String] = [:]
        var pendingDocuments: [String:String]?
        var uncertain: Set<String> = []
    }
    private let lock = NSRecursiveLock()
    private let uiLock = NSLock()
    private var cachedAuthenticated = false
    private var cachedFolderURL: URL?
    private let queue = DispatchQueue(label: "voiceinput.google")
    // Main-thread only. Repeated clicks reopen the current flow instead of queuing five-minute waits.
    private var connecting = false
    private var authorizationURL: URL?
    private var access: (String, Date)?
    private let service = "jp.ishot.VoiceInput.GoogleMeetings"
    private let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".voice-input/google-meetings")
    private var state: State = State()
    private let scope = "https://www.googleapis.com/auth/drive.file https://www.googleapis.com/auth/meetings.space.readonly"
    private init() {
        if let data = try? Data(contentsOf: base.appendingPathComponent("state.json")), let value = try? JSONDecoder().decode(State.self, from: data) { state = value }
        cachedAuthenticated = credentials() != nil
        cachedFolderURL = state.folderID.flatMap { URL(string: "https://drive.google.com/drive/folders/\($0)") }
    }
    var isConfigured: Bool { isAuthenticated }
    var isAuthenticated: Bool { uiLock.lock(); defer { uiLock.unlock() }; return cachedAuthenticated }
    var folderURL: URL? { uiLock.lock(); defer { uiLock.unlock() }; return cachedFolderURL }
    private func publishUI() {
        let folder = state.folderID.flatMap { URL(string: "https://drive.google.com/drive/folders/\($0)") }
        uiLock.lock(); cachedFolderURL = folder; uiLock.unlock()
    }
    private func credentials() -> Credentials? {
        var item: CFTypeRef?
        let q: [String:Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service, kSecAttrAccount as String:"oauth", kSecReturnData as String:true]
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from:data)
    }
    private func store(_ value: Credentials) throws {
        let data = try JSONEncoder().encode(value)
        let q: [String:Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service, kSecAttrAccount as String:"oauth"]
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw Failure(message:"Google接続情報をキーチェーンに保存できません。") }
        } else if status != errSecSuccess { throw Failure(message:"Google接続情報を更新できません。") }
        uiLock.lock(); cachedAuthenticated = true; uiLock.unlock()
    }
    private func save() throws {
        defer { publishUI() }
        try FileManager.default.createDirectory(at:base, withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
        let url = base.appendingPathComponent("state.json")
        try JSONEncoder().encode(state).write(to:url, options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:url.path)
        if let account = state.accountID { let archive = base.appendingPathComponent("account-\(account).json"); try JSONEncoder().encode(state).write(to:archive, options:.atomic); try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:archive.path) }
    }
    func connect(completion: @escaping (Result<Void,Error>) -> Void) {
        dispatchPrecondition(condition:.onQueue(.main))
        if connecting {
            if let url = authorizationURL { openAuthorization(url) { _ in } }
            return
        }
        if let old = credentials() {
            beginLogin(client: old.client, completion: completion)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel(); panel.title = "Google Cloudのデスクトップ用OAuthクライアントJSONを選択"; panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { completion(.failure(Failure(message:"Google接続をキャンセルしました。"))); return }
            self.connect(clientURL: url, completion: completion)
        }
    }
    /// Explicit setup entry point for a desktop client JSON; never prints credentials.
    func connect(clientURL: URL, completion: @escaping (Result<Void,Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        do {
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: clientURL)) as? [String:Any]
            guard let installed = root?["installed"], JSONSerialization.isValidJSONObject(installed) else {
                throw Failure(message: "デスクトップアプリ用のOAuthクライアントJSONを選んでください。")
            }
            let client = try JSONDecoder().decode(Client.self, from: JSONSerialization.data(withJSONObject: installed))
            guard client.client_id.hasSuffix(".apps.googleusercontent.com") else {
                throw Failure(message: "GoogleのOAuthクライアントIDを確認してください。")
            }
            beginLogin(client: client, completion: completion)
        } catch { completion(.failure(error)) }
    }
    private func beginLogin(client: Client, completion: @escaping (Result<Void,Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !connecting else { return }
        connecting = true
        Log.write("Google再接続: 開始")
        queue.async {
            self.login(client: client) { result in
                self.connecting = false
                self.authorizationURL = nil
                switch result {
                case .success: Log.write("Google再接続: 完了")
                case .failure(let error): Log.write("Google再接続: " + error.localizedDescription)
                }
                completion(result)
            }
        }
    }
    private func openAuthorization(_ url: URL, completion: @escaping (Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        let workspace = NSWorkspace.shared
        guard let browser = workspace.urlForApplication(withBundleIdentifier: "com.google.Chrome")
                ?? workspace.urlForApplication(toOpen: url) else {
            completion(false); return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.open([url], withApplicationAt: browser, configuration: configuration) { app, error in
            Log.write("Google再接続: ブラウザー起動 " + (app != nil && error == nil ? "成功" : "失敗"))
            completion(app != nil && error == nil)
        }
    }
    private func login(client: Client, completion: @escaping (Result<Void,Error>)->Void) {
        do {
            let listener = try Loopback()
            defer { listener.closeSocket() }
            let verifier = Self.random(), nonce = Self.random()
            let challenge = Data(SHA256.hash(data:Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
            let redirect = "http://127.0.0.1:\(listener.port)/oauth"
            var url = URLComponents(string:"https://accounts.google.com/o/oauth2/v2/auth")!
            url.queryItems = ["client_id":client.client_id,"redirect_uri":redirect,"response_type":"code","scope":scope,"code_challenge":challenge,"code_challenge_method":"S256","state":nonce,"access_type":"offline","prompt":"consent select_account"].map { URLQueryItem(name:$0.key,value:$0.value) }
            let opened = DispatchSemaphore(value: 0)
            let resultLock = NSLock()
            var didOpen = false
            let authURL = url.url!
            DispatchQueue.main.async {
                self.authorizationURL = authURL
                self.openAuthorization(authURL) { success in
                    resultLock.lock(); didOpen = success; resultLock.unlock()
                    opened.signal()
                }
            }
            guard opened.wait(timeout: .now() + 20) == .success else {
                throw Failure(message: "Google認証画面を開けませんでした。Chromeを起動して、もう一度Google連携を押してください。")
            }
            resultLock.lock(); let launched = didOpen; resultLock.unlock()
            guard launched else { throw Failure(message: "Google認証用のブラウザーを開けませんでした。Chromeを起動して再接続してください。") }
            let code = try listener.code(state:nonce)
            let result = try token(["client_id":client.client_id,"client_secret":client.client_secret ?? "","code":code,"code_verifier":verifier,"redirect_uri":redirect,"grant_type":"authorization_code"])
            guard let refresh = result["refresh_token"] as? String else { throw Failure(message:"Googleから継続接続の許可を取得できませんでした。再接続してください。") }
            lock.lock(); defer { lock.unlock() }
            guard let accessToken = result["access_token"] as? String else { throw Failure(message:"Google認証の応答に問題があります。") }
            access = (accessToken,Date().addingTimeInterval(result["expires_in"] as? Double ?? 3600))
            // Account changes must never reuse another account's folder/document IDs.
            let about = try api("https://www.googleapis.com/drive/v3/about", query:["fields":"user(permissionId)"])
            guard let user = about["user"] as? [String:Any], let rawID = user["permissionId"] as? String else { throw Failure(message:"保存先アカウントを確認できません。") }
            let account = SHA256.hash(data:Data(rawID.utf8)).map { String(format:"%02x",$0) }.joined()
            try store(Credentials(client:client,refreshToken:refresh,accountID:account))
            if state.accountID != account {
                if let data = try? Data(contentsOf:base.appendingPathComponent("account-\(account).json")), let saved = try? JSONDecoder().decode(State.self,from:data) { state = saved } else { state = State(); state.accountID = account }
            }
            try save()
            _ = try ensureFolder()
            DispatchQueue.main.async { completion(.success(())) }
        } catch { lock.lock(); access = nil; lock.unlock(); DispatchQueue.main.async { completion(.failure(error)) } }
    }
    private static func random() -> String { var bytes = [UInt8](repeating:0,count:32); precondition(SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess); return Data(bytes).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") }
    private func token(_ fields:[String:String]) throws -> [String:Any] {
        var request = URLRequest(url:URL(string:"https://oauth2.googleapis.com/token")!); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField:"Content-Type")
        request.httpBody = Self.form(fields).data(using:.utf8)
        return try send(request)
    }
    static func form(_ fields:[String:String]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"-._~"))
        return fields.sorted(by:{$0.key < $1.key}).map { "\($0.key.addingPercentEncoding(withAllowedCharacters:allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters:allowed)!)" }.joined(separator:"&")
    }
    private func bearer() throws -> String {
        if let a = access, a.1.timeIntervalSinceNow > 60 { return a.0 }
        guard let c = credentials() else { throw Failure(message:"メニューからGoogleドライブに接続してください。") }
        let value = try token(["client_id":c.client.client_id,"client_secret":c.client.client_secret ?? "","refresh_token":c.refreshToken,"grant_type":"refresh_token"])
        guard let text = value["access_token"] as? String else { throw Failure(message:"Googleに再接続してください。") }
        access = (text,Date().addingTimeInterval(value["expires_in"] as? Double ?? 3600)); return text
    }
    private func send(_ input:URLRequest) throws -> [String:Any] {
        var request = input; request.timeoutInterval = 60
        let semaphore = DispatchSemaphore(value:0)
        var data:Data?, response:URLResponse?, failure:Error?
        let session = URLSession(configuration:.ephemeral)
        let task = session.dataTask(with:request) { d,r,e in data=d; response=r; failure=e; semaphore.signal() }
        task.resume()
        guard semaphore.wait(timeout:.now()+65) == .success else { task.cancel(); session.invalidateAndCancel(); throw Failure(message:"Googleの応答を確認できません。議事録はMacに保持しています。") }
        session.finishTasksAndInvalidate()
        if let failure { throw failure }
        guard let http = response as? HTTPURLResponse else { throw Failure(message:"Googleの応答を確認できません。") }
        guard (200..<300).contains(http.statusCode) else {
            // Never expose raw response bodies containing customer data or OAuth credentials.
            let endpoint = request.url?.path ?? "unknown"
            Log.write("Google API失敗 HTTP=\(http.statusCode) endpoint=\(endpoint)")
            if endpoint == "/token", http.statusCode == 400 {
                throw Failure(message:"Googleの認証更新に失敗しました。VoiceInputのメニューからGoogleドライブへ再接続してください。録音と文字起こしはMacに保持しています。", status: http.statusCode)
            }
            throw Failure(message:"Google接続エラー（HTTP \(http.statusCode)）。APIの有効化・アカウントの権限・接続設定を確認してください。",status:http.statusCode)
        }
        return (try JSONSerialization.jsonObject(with:data ?? Data("{}".utf8))) as? [String:Any] ?? [:]
    }
    private func api(_ path:String, query:[String:String]=[:], method:String="GET", json:[String:Any]?=nil, payload:Data?=nil, contentType:String?=nil) throws -> [String:Any] {
        var parts = URLComponents(string:path)!
        parts.queryItems = query.map { URLQueryItem(name:$0.key,value:$0.value) }
        var req = URLRequest(url:parts.url!); req.httpMethod = method; req.setValue("Bearer \(try bearer())",forHTTPHeaderField:"Authorization")
        if let json { req.httpBody = try JSONSerialization.data(withJSONObject:json); req.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        if let payload { req.httpBody = payload; req.setValue(contentType,forHTTPHeaderField:"Content-Type") }
        return try send(req)
    }
    private func files(property:String,value:String) throws -> [[String:Any]] {
        let safe = value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"'",with:"\\'")
        return try pages("https://www.googleapis.com/drive/v3/files", key:"files",query:["q":"trashed = false and appProperties has { key='\(property)' and value='\(safe)' }", "fields":"files(id,mimeType),nextPageToken"])
    }
    private func ensureFolder() throws -> String {
        if let id = state.folderID {
            // A pre-generated ID makes a repeated folder-create safe even after a lost response.
            if let folder = try? api("https://www.googleapis.com/drive/v3/files/\(id)",query:["fields":"id,trashed,mimeType"]) {
                guard folder["trashed"] as? Bool != true, folder["mimeType"] as? String == "application/vnd.google-apps.folder" else { throw Failure(message:"会議議事録フォルダをごみ箱から復元してください。") }; return id
            }
        } else if let id = try files(property:"voiceInputFolder",value:"meetings").first?["id"] as? String {
            state.folderID = id; try save(); return id
        }
        if state.folderID == nil {
            let ids = try api("https://www.googleapis.com/drive/v3/files/generateIds",query:["count":"1","space":"drive"])
            guard let id = (ids["ids"] as? [String])?.first else { throw Failure(message:"保存フォルダを準備できません。") }
            state.folderID = id; try save()
        }
        let id = state.folderID!
        _ = try api("https://www.googleapis.com/drive/v3/files",query:["fields":"id"],method:"POST",json:["id":id,"name":"会議議事録","mimeType":"application/vnd.google-apps.folder","parents":["root"],"appProperties":["voiceInputFolder":"meetings"]])
        return id
    }
    func export(title:String, body:String, meetingID:String) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard let c = credentials(), state.accountID == c.accountID else { throw Failure(message:"Googleドライブに再接続して保存先を確認してください。") }
        guard !meetingID.isEmpty else { throw Failure(message:"会議IDがありません。") }
        if let id = state.documents[meetingID] { try verifyDocument(id:id, body:body); return documentURL(id) }
        if let id = state.pendingDocuments?[meetingID] { return try completeDocument(id:id,body:body,meetingID:meetingID) }
        let matches = try files(property:"voiceInputMeeting",value:meetingID)
        guard matches.count <= 1 else { throw Failure(message:"同じ会議IDの文書が複数あります。保存先を確認してください。") }
        if let id = matches.first?["id"] as? String { return try completeDocument(id:id,body:body,meetingID:meetingID) }
        guard !state.uncertain.contains(meetingID) else { throw Failure(message:"前回のGoogle保存結果が未確認です。重複を防ぐため再作成を止めています。Driveの会議議事録フォルダを確認してください。") }
        let folder = try ensureFolder(), boundary = "voiceinput-\(UUID().uuidString)"
        let metadata:[String:Any] = ["name":title,"mimeType":"application/vnd.google-apps.document","parents":[folder],"appProperties":["voiceInputMeeting":meetingID]]
        var upload = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        upload.append(try JSONSerialization.data(withJSONObject:metadata))
        upload.append(Data("\r\n--\(boundary)\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n\(body)\r\n--\(boundary)--\r\n".utf8))
        state.uncertain.insert(meetingID); try save()
        let result: [String:Any]
        do { result = try api("https://www.googleapis.com/upload/drive/v3/files",query:["uploadType":"multipart","fields":"id"],method:"POST",payload:upload,contentType:"multipart/related; boundary=\(boundary)") } catch {
            if let failure = error as? Failure, let status = failure.status, [400,401,403,404,413,415,422,429].contains(status) { state.uncertain.remove(meetingID); try save() }
            throw error
        }
        guard let id = result["id"] as? String else { throw Failure(message:"Google保存結果が未確認です。") }
        return try completeDocument(id:id,body:body,meetingID:meetingID)
    }
    /// Read-before-write + revision precondition. A changed document is preserved as-is;
    /// appends continue in a new version instead of overwriting the user's work.
    func syncTranscript(title: String, body: String, meetingID: String) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let desired = TranscriptAppend.normalized(body)
        let hash = ClientDictionary.digest(desired)
        var stream = state.transcriptStreams?[meetingID] ?? StreamState(key: meetingID + "-transcript-live", hash: "", pendingHash: nil)
        if state.transcriptStreams == nil { state.transcriptStreams = [:] }
        if let id = state.documents[stream.key] ?? state.pendingDocuments?[stream.key] {
            let document = try api("https://docs.googleapis.com/v1/documents/\(id)")
            let actual = Self.documentText(document["body"] ?? [:])
            switch TranscriptAppend.decide(actual: actual, desired: desired, previousHash: stream.hash) {
            case .complete:
                stream.hash = hash; stream.pendingHash = nil
                state.transcriptStreams?[meetingID] = stream; try save()
                return documentURL(id)
            case .append(let suffix):
                guard let revision = document["revisionId"] as? String else { throw Failure(message: "Google文書の版を確認できません。送信待ちを維持します。") }
                stream.pendingHash = hash; state.transcriptStreams?[meetingID] = stream; try save()
                // Insert before the final Docs newline, preserving existing paragraphs.
                let insertion = max(1, (actual as NSString).length)
                _ = try api("https://docs.googleapis.com/v1/documents/\(id):batchUpdate", method: "POST", json: [
                    "writeControl": ["requiredRevisionId": revision],
                    "requests": [["insertText": ["location": ["index": insertion], "text": suffix]]]])
                let reread = try api("https://docs.googleapis.com/v1/documents/\(id)")
                guard TranscriptAppend.normalized(Self.documentText(reread["body"] ?? [:])) == desired else { throw Failure(message: "原文の追記結果を確認できません。再送前に読み戻します。") }
                stream.hash = hash; stream.pendingHash = nil
                state.transcriptStreams?[meetingID] = stream; try save()
                return documentURL(id)
            case .fork:
                stream = StreamState(key: meetingID + "-transcript-live-" + UUID().uuidString, hash: "", pendingHash: nil)
                state.transcriptStreams?[meetingID] = stream; try save()
            }
        } else if stream.hash.isEmpty {
            state.transcriptStreams?[meetingID] = stream; try save()
        }
        let result = try export(title: title, body: desired, meetingID: stream.key)
        stream.hash = hash; stream.pendingHash = nil
        state.transcriptStreams?[meetingID] = stream; try save()
        return result
    }

    private func documentURL(_ id:String) -> URL { URL(string:"https://docs.google.com/document/d/\(id)/edit")! }
    private func completeDocument(id:String,body:String,meetingID:String) throws -> URL {
        // Durable remote ID precedes read-back: a failed verification must never create another Doc.
        if state.pendingDocuments == nil { state.pendingDocuments = [:] }
        state.pendingDocuments?[meetingID] = id; state.uncertain.remove(meetingID); try save()
        try verifyDocument(id:id,body:body)
        state.documents[meetingID] = id; state.pendingDocuments?.removeValue(forKey:meetingID); try save()
        return documentURL(id)
    }
    private func verifyDocument(id:String,body:String) throws {
        let document = try api("https://docs.googleapis.com/v1/documents/\(id)")
        let actual = Self.documentText(document["body"] ?? [:])
        guard Self.documentContains(actual:actual,expected:body) else {
            throw Failure(message:"Googleドキュメントの本文を確認できません。Macの議事録と保存先の文書を保持し、重複作成せずに再確認します。")
        }
    }
    static func documentText(_ value:Any) -> String {
        if let object = value as? [String:Any] {
            if let run = object["textRun"] as? [String:Any], let content = run["content"] as? String { return content }
            // Walk the documented structural order; dictionary iteration would scramble paragraphs.
            for key in ["content","elements","tableRows","tableCells"] {
                if let children = object[key] as? [Any] { return children.map(documentText).joined() }
            }
            if let paragraph = object["paragraph"] { return documentText(paragraph) }
            if let table = object["table"] { return documentText(table) }
        }
        return ""
    }
    static func documentContains(actual:String,expected:String) -> Bool {
        func normalize(_ text:String) -> String { text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n").trimmingCharacters(in:.newlines) }
        let wanted = normalize(expected)
        return !wanted.isEmpty && normalize(actual).contains(wanted)
    }
    private func pages(_ url:String,key:String,query:[String:String]=[:]) throws -> [[String:Any]] {
        var q=query, output:[[String:Any]]=[]
        for _ in 0..<200 {
            let result=try api(url,query:q); output += result[key] as? [[String:Any]] ?? []
            guard let next=result["nextPageToken"] as? String,!next.isEmpty else { return output }
            q["pageToken"]=next
        }
        throw Failure(message:"Googleの会議データが多すぎるため、全件取得を確認できません。")
    }
    private static func date(_ value:Any?) -> Date? {
        guard let s=value as? String else { return nil }; let f=ISO8601DateFormatter(); f.formatOptions=[.withInternetDateTime,.withFractionalSeconds]; return f.date(from:s) ?? ISO8601DateFormatter().date(from:s)
    }
    /// Reads participants independently of transcript availability, including during a call.
    func activeParticipantNames(meetingCode: String) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard meetingCode.range(of: "^[a-z]{3}-[a-z]{4}-[a-z]{3}$", options: .regularExpression) != nil else { return [] }
        let space = try api("https://meet.googleapis.com/v2/spaces/" + meetingCode)
        guard let active = space["activeConference"] as? [String:Any], let conference = active["conferenceRecord"] as? String else { return [] }
        let participants = try pages("https://meet.googleapis.com/v2/" + conference + "/participants", key: "participants", query: ["filter":"latest_end_time IS NULL"])
        return participants.compactMap { participant in
            for kind in ["signedinUser", "anonymousUser", "phoneUser"] {
                if let user = participant[kind] as? [String:Any], let name = user["displayName"] as? String { return name }
            }
            return nil
        }
    }
    func participantSessions(meetingCode: String, startedAt: Date, endedAt: Date) throws -> [MeetingParticipantSession] {
        lock.lock(); defer { lock.unlock() }
        guard meetingCode.range(of: "^[a-z]{3}-[a-z]{4}-[a-z]{3}$", options: .regularExpression) != nil else { return [] }
        let iso=ISO8601DateFormatter()
        let timeFilter = "start_time >= \"\(iso.string(from:startedAt.addingTimeInterval(-86400)))\" AND start_time <= \"\(iso.string(from:endedAt))\""
        let filter = meetingCode.isEmpty ? timeFilter : "space.meeting_code = \"\(meetingCode)\" AND \(timeFilter)"
        let records=try pages("https://meet.googleapis.com/v2/conferenceRecords",key:"conferenceRecords",query:["filter":filter])
        let relevant=records.filter { r in guard let s=Self.date(r["startTime"]) else { return false }; let e=Self.date(r["endTime"]) ?? Date(); return s <= endedAt && e >= startedAt }
        guard relevant.count == 1, let record=relevant.first?["name"] as? String else { throw Failure(message:"対応するMeet会議を一意に確認できません。主催者権限と会議コードを確認してください。") }
        let participants=try pages("https://meet.googleapis.com/v2/\(record)/participants",key:"participants")
        var result: [MeetingParticipantSession] = []
        for p in participants {
            guard let id = p["name"] as? String else { continue }
            let name = ["signedinUser", "anonymousUser", "phoneUser"].compactMap { (p[$0] as? [String:Any])?["displayName"] as? String }.first
            guard let name, !name.isEmpty else { continue }
            for session in try pages("https://meet.googleapis.com/v2/" + id + "/participantSessions", key: "participantSessions") {
                guard let start = Self.date(session["startTime"]) else { continue }
                let end = Self.date(session["endTime"]) ?? endedAt
                if end > startedAt && start < endedAt { result.append(.init(id: id, name: name, start: start.timeIntervalSince1970, end: end.timeIntervalSince1970)) }
            }
        }
        return result
    }
    func fetchTranscript(meetingCode:String,startedAt:Date,endedAt:Date) throws -> [GoogleMeetingEntry] {
        lock.lock(); defer { lock.unlock() }
        guard meetingCode.isEmpty || meetingCode.range(of:"^[a-z]{3}-[a-z]{4}-[a-z]{3}$",options:.regularExpression) != nil else { throw Failure(message:"Meetの会議コードを確認してください。") }
        let iso=ISO8601DateFormatter()
        let timeFilter = "start_time >= \"\(iso.string(from:startedAt.addingTimeInterval(-86400)))\" AND start_time <= \"\(iso.string(from:endedAt))\""
        let filter = meetingCode.isEmpty ? timeFilter : "space.meeting_code = \"\(meetingCode)\" AND \(timeFilter)"
        let records=try pages("https://meet.googleapis.com/v2/conferenceRecords",key:"conferenceRecords",query:["filter":filter])
        let relevant=records.filter { r in guard let s=Self.date(r["startTime"]) else { return false }; let e=Self.date(r["endTime"]) ?? Date(); return s <= endedAt && e >= startedAt }
        guard relevant.count == 1, let record=relevant.first?["name"] as? String else { throw Failure(message:"対応するMeet会議を一意に確認できません。主催者権限と会議コードを確認してください。") }
        let participants=try pages("https://meet.googleapis.com/v2/\(record)/participants",key:"participants")
        var names:[String:String]=[:]
        for p in participants { guard let name=p["name"] as? String else { continue }; for type in ["signedinUser","anonymousUser","phoneUser"] { if let detail=p[type] as? [String:Any],let display=detail["displayName"] as? String { names[name]=display } } }
        let transcripts=try pages("https://meet.googleapis.com/v2/\(record)/transcripts",key:"transcripts")
        guard !transcripts.isEmpty, transcripts.allSatisfy({ ($0["state"] as? String) == "FILE_GENERATED" }) else { throw Failure(message:"Meet公式文字起こしが未生成です。Meetで文字起こしを有効にし、生成後に再試行してください。") }
        var entries:[GoogleMeetingEntry]=[]
        for t in transcripts { guard let name=t["name"] as? String else { continue }
            for e in try pages("https://meet.googleapis.com/v2/\(name)/entries",key:"transcriptEntries") {
                guard let start=Self.date(e["startTime"]),let end=Self.date(e["endTime"]),let text=e["text"] as? String, end>=startedAt,start<=endedAt else { continue }
                entries.append(GoogleMeetingEntry(speaker:names[e["participant"] as? String ?? ""] ?? "話者未確認",text:text,start:start,end:end))
            }
        }
        guard !entries.isEmpty else { throw Failure(message:"録音時間内のMeet公式発言データがまだありません。") }
        return entries.sorted { $0.start < $1.start }
    }
    static func selfTest() -> Bool {
        let doc:[String:Any] = ["content":[["paragraph":["elements":[["textRun":["content":"決定事項\n"]]]]], ["paragraph":["elements":[["textRun":["content":"担当者：田中\n"]]]]]]]
        guard documentText(doc) == "決定事項\n担当者：田中\n", documentContains(actual:documentText(doc),expected:"決定事項\r\n担当者：田中\n"), !documentContains(actual:documentText(doc),expected:"担当者：鈴木") else { return false }
        guard form(["x":"a+b &日本"]) == "x=a%2Bb%20%26%E6%97%A5%E6%9C%AC" else { return false }
        guard date("2026-09-15T01:02:03.123Z") != nil, date("2026-09-15T01:02:03Z") != nil else { return false }
        do {
            let socket = try Loopback(); defer { socket.closeSocket() }
            let nonce = random()
            DispatchQueue.global().async {
                let url = URL(string:"http://127.0.0.1:\(socket.port)/oauth?state=\(nonce)&code=test-code")!
                URLSession.shared.dataTask(with:url) { _,_,_ in }.resume()
            }
            guard try socket.code(state:nonce) == "test-code" else { return false }
            return true
        } catch { return false }
    }
    private final class Loopback {
        private var fd:Int32 = -1
        private(set) var port: UInt16 = 0
        init() throws {
            fd=socket(AF_INET,SOCK_STREAM,0)
            guard fd>=0 else { throw Failure(message:"Google認証の受信口を作成できません。") }
            var addr=sockaddr_in(); addr.sin_len=UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family=sa_family_t(AF_INET); addr.sin_addr.s_addr=inet_addr("127.0.0.1"); addr.sin_port=0
            let bound=withUnsafePointer(to:&addr) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard bound==0,listen(fd,4)==0 else { Darwin.close(fd); throw Failure(message:"Google認証の受信口を開けません。") }
            var length=socklen_t(MemoryLayout<sockaddr_in>.size)
            _=withUnsafeMutablePointer(to:&addr) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(fd,$0,&length) } }
            port=UInt16(bigEndian:addr.sin_port)
        }
        func closeSocket() { if fd>=0 { Darwin.close(fd); fd = -1 } }
        func code(state:String) throws -> String {
            let deadline=Date().addingTimeInterval(300)
            while Date()<deadline {
                var event=pollfd(fd:fd,events:Int16(POLLIN),revents:0)
                guard poll(&event,1,1000)>0 else { continue }
                let client=accept(fd,nil,nil); guard client>=0 else { continue }
                defer { Darwin.close(client) }
                var noSignal:Int32=1; setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
                var timeout=timeval(tv_sec:2,tv_usec:0); setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
                var requestData=Data(), bytes=[UInt8](repeating:0,count:2048)
                while requestData.count < 8192 { let n=recv(client,&bytes,bytes.count,0); if n <= 0 { break }; requestData.append(contentsOf:bytes.prefix(n)); if requestData.range(of:Data("\r\n\r\n".utf8)) != nil { break } }
                guard requestData.count <= 8192,let line=String(data:requestData,encoding:.utf8)?.components(separatedBy:"\r\n").first else { continue }
                let parts=line.split(separator:" "); guard parts.count>=2, parts[0]=="GET", let url=URLComponents(string:"http://127.0.0.1\(parts[1])"),url.path=="/oauth" else { continue }
                guard let queryItems=url.queryItems, Set(queryItems.map(\.name)).count == queryItems.count else { continue }
                let values=Dictionary(url.queryItems?.map { ($0.name,$0.value ?? "") } ?? [],uniquingKeysWith:{ first,_ in first })
                guard values["state"]==state else { continue }
                let response="HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\nVoiceInputに戻ってください。この画面は閉じられます。"
                _=response.withCString { Darwin.send(client,$0,strlen($0),0) }
                guard let code=values["code"],!code.isEmpty else { throw Failure(message:"Googleへの接続が許可されませんでした。") }; return code
            }
            throw Failure(message:"Google接続の待ち時間が終了しました。メニューから再接続できます。")
        }
    }
}
