import Foundation
import AVFoundation

/// Separate speech/noise classification from ASR. Fail visibly if the classifier is unavailable.
enum MeetingSpeech {
    struct Interval: Decodable { let start: Double; let end: Double }
    static func intervals(_ audio: URL) throws -> [Interval] {
        guard let helper = Bundle.main.url(forResource: "meeting-vad", withExtension: "py") else {
            throw MeetingFailure.message("会議の発話検出プログラムがありません。アプリを更新してください。")
        }
        let model = MeetingRecognition.models.appendingPathComponent("silero_vad.onnx")
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw MeetingFailure.message("会議の発話検出モデルがありません。setup-meeting-models.shを実行してください。")
        }
        let data = try Polisher.runCLI(path: MeetingRecognition.python.path, arguments: [helper.path, "--audio", audio.path, "--model", model.path], timeout: 60, stage: "会議発話検出", cancelled: { false })
        let intervals = try JSONDecoder().decode([Interval].self, from: data)
        guard intervals.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }) else { throw MeetingFailure.message("発話検出の時刻が不正です。") }
        return intervals
    }
    static func transcribe(_ audio: URL, settings: Settings) throws -> String {
        let ranges = try intervals(audio)
        guard !ranges.isEmpty else { return "" }
        guard let whisper = settings.resolvedWhisper else { throw Transcriber.TranscribeError.whisperMissing }
        return try Transcriber(whisperPath: whisper, modelPath: settings.resolvedMeetingModel, language: settings.language, initialPrompt: "", fastMode: false).transcribe(audio).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
