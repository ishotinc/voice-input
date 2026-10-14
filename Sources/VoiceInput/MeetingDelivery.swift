import Foundation

enum MeetingDelivery {
    /// Publish an immutable source copy before asking any generative AI to edit it.
    /// The final minutes use a separate ID so retries never overwrite user edits.
    static func checkpoint(record: inout MeetingRecord, export: (String, String, String) throws -> URL) throws {
        guard !record.utterances.isEmpty, record.transcriptDocumentURL == nil else { return }
        let body = MeetingMinutes.transcript(record: record, notice: "未校正の文字起こしです。AI校正・要約前の原記録として保存しています。")
        let url = try export(record.displayTitle + "｜未校正の文字起こし", body, record.id + "-transcript")
        record.transcriptDocumentURL = url.absoluteString
    }
    static func correct(record: inout MeetingRecord, operation: (inout MeetingRecord) throws -> Void) throws -> Bool {
        let original = record
        do { try operation(&record); return true }
        catch Polisher.PolishError.cancelled { record = original; throw Polisher.PolishError.cancelled }
        catch {
            record = original
            record.warnings.append("AI校正が完了しなかったため、未校正の文字起こしを保存しました。音声と原文から再処理できます。")
            Log.write("会議校正未完了: 原文の保存へ継続")
            return false
        }
    }
}
