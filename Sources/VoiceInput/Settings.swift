import Foundation

/// メニューバーから変えられる設定。~/.voice-input/settings.json に置く。
struct Settings: Codable {
    /// Claude Code Max で仕上げるか。ユーザー指定により既定オン。
    var polishWithClaude: Bool = true
    var jev = JevSettings()
    /// 文字起こしの言語。
    var language: String = "ja"
    /// whisper-cli の場所。空なら自動で探す。
    var whisperPath: String = ""
    /// モデルの場所。空なら ~/.voice-input/models/ の既定モデル。
    var modelPath: String = ""
    var useMLXForDictation: Bool = false
    var mlxForDictation: Bool { useMLXForDictation && resolvedModel.lastPathComponent == "ggml-large-v3-turbo-q5_0.bin" }
    /// 「〜じゃなくて、〜」の言い直しで前半を落とすか。
    var dropSelfCorrections: Bool = true
    /// 録音を始めたときに鳴らす音。空文字なら鳴らさない。
    /// /System/Library/Sounds の名前（Pop / Tink / Ping / Bottle / Submarine / Morse / Glass …）。
    var startSound: String = "Tink"
    /// 録音を止めたときに鳴らす音。
    var stopSound: String = "Pop"
    /// 英数字と日本語の間に半角スペースを入れるか。
    var spaceAroundLatin: Bool = true
    /// 末尾の「。」を落とすか。
    var trimTrailingPeriod: Bool = true
    /// 変換後に .wav を残すか。既定はオフ（変換後すぐ消す）。
    var keepAudioForDebug: Bool = false
    /// 使いたくない語のリスト（JSON）のパス。空なら使わない。ここから読むだけで、書き換えはしない。
    var styleWordsPath: String = ""
    /// Claude 仕上げに使うモデル。
    var polishModel: String = "claude-sonnet-5"
    var polishEffort: String = "low"
    /// AI の仕上げに使うもの。既定は Claude（今までどおり）。選んだものが使えないときは別の会社の AI に切り替えない。
    var aiProvider: AIProvider = .claude
    /// OpenAI（API キー・Codex CLI 共通）で使うモデルと思考量。gpt-6.1-sol は low〜max（none/minimal は不可）。
    var openAIModel: String = "gpt-6.1-sol"
    var openAIEffort: String = "low"

    /// Read the target input field locally at recording start.
    var useScreenContext: Bool = true
    /// Separate consent: send bounded context to Claude only when both toggles are on.
    var shareScreenContextWithClaude: Bool = true
    /// User's formatting preferences, subordinate to preserving the spoken content.
    var customPolishInstructions: String = ""

    var selectedClientFolder: String = ""
    var clientNameAliases: [String: [String: String]] = [:]

    init() {}

    /// 設定項目が増えても、古い settings.json を壊さず既定値で埋める。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        jev = try c.decodeIfPresent(JevSettings.self, forKey: .jev) ?? d.jev
        polishWithClaude = try c.decodeIfPresent(Bool.self, forKey: .polishWithClaude) ?? d.polishWithClaude
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        whisperPath = try c.decodeIfPresent(String.self, forKey: .whisperPath) ?? d.whisperPath
        modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath) ?? d.modelPath
        useMLXForDictation = try c.decodeIfPresent(Bool.self, forKey: .useMLXForDictation) ?? d.useMLXForDictation
        dropSelfCorrections = try c.decodeIfPresent(Bool.self, forKey: .dropSelfCorrections) ?? d.dropSelfCorrections
        startSound = try c.decodeIfPresent(String.self, forKey: .startSound) ?? d.startSound
        stopSound = try c.decodeIfPresent(String.self, forKey: .stopSound) ?? d.stopSound
        spaceAroundLatin = try c.decodeIfPresent(Bool.self, forKey: .spaceAroundLatin) ?? d.spaceAroundLatin
        trimTrailingPeriod = try c.decodeIfPresent(Bool.self, forKey: .trimTrailingPeriod) ?? d.trimTrailingPeriod
        keepAudioForDebug = try c.decodeIfPresent(Bool.self, forKey: .keepAudioForDebug) ?? d.keepAudioForDebug
        styleWordsPath = try c.decodeIfPresent(String.self, forKey: .styleWordsPath) ?? d.styleWordsPath
        polishModel = try c.decodeIfPresent(String.self, forKey: .polishModel) ?? d.polishModel
        polishEffort = try c.decodeIfPresent(String.self, forKey: .polishEffort) ?? d.polishEffort
        aiProvider = (try? c.decodeIfPresent(AIProvider.self, forKey: .aiProvider)) ?? d.aiProvider
        openAIModel = try c.decodeIfPresent(String.self, forKey: .openAIModel) ?? d.openAIModel
        openAIEffort = try c.decodeIfPresent(String.self, forKey: .openAIEffort) ?? d.openAIEffort
        useScreenContext = try c.decodeIfPresent(Bool.self, forKey: .useScreenContext) ?? d.useScreenContext
        shareScreenContextWithClaude = try c.decodeIfPresent(Bool.self, forKey: .shareScreenContextWithClaude) ?? d.shareScreenContextWithClaude
        selectedClientFolder = try c.decodeIfPresent(String.self, forKey: .selectedClientFolder) ?? d.selectedClientFolder
        clientNameAliases = try c.decodeIfPresent([String: [String: String]].self, forKey: .clientNameAliases) ?? d.clientNameAliases
        customPolishInstructions = try c.decodeIfPresent(String.self, forKey: .customPolishInstructions) ?? d.customPolishInstructions
    }

    static func load() -> Settings {
        do {
            let data = try Data(contentsOf: Paths.settings)
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            if FileManager.default.fileExists(atPath: Paths.settings.path) {
                Log.write("settings.json を読めなかったので既定値を使う: \(error)")
            }
            let fresh = Settings()
            fresh.save()
            return fresh
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Paths.settings)
    }

    /// 実際に使う whisper-cli。見つからなければ nil。
    var resolvedWhisper: String? {
        if !whisperPath.isEmpty, FileManager.default.isExecutableFile(atPath: whisperPath) {
            return whisperPath
        }
        return Paths.whisperCandidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    var resolvedMeetingModel: URL {
        let full = Paths.models.appendingPathComponent("ggml-large-v3-q5_0.bin")
        return FileManager.default.fileExists(atPath: full.path) ? full : resolvedModel
    }

    var resolvedModel: URL {
        modelPath.isEmpty ? Paths.defaultModel : URL(fileURLWithPath: modelPath)
    }
}
