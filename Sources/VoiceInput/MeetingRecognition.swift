import Foundation
import AVFoundation

struct MeetingRecognition {
    struct Segment: Codable { var start: Double; var end: Double; var speaker: String }
    static var python: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".voice-input/meeting-runtime/bin/python") }
    static var models: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".voice-input/meeting-models") }
    static var helper: URL? { Bundle.main.url(forResource: "meeting-diarize", withExtension: "py") }
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: python.path) && helper != nil && ["segmentation.onnx", "embedding.onnx"].allSatisfy { FileManager.default.fileExists(atPath: models.appendingPathComponent($0).path) } }
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    /// Stream to disk in 1-second buffers, inserting silence for callback timing gaps.
    static func combine(_ chunks: [MeetingAudioCapture.Chunk], output: URL) throws {
        let file = try AVAudioFile(forWriting: output, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
        var written: AVAudioFramePosition = 0
        for chunk in chunks.sorted(by: { $0.startSeconds < $1.startSeconds }) {
            let input = try AVAudioFile(forReading: chunk.url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let target = AVAudioFramePosition((chunk.startSeconds * 16000).rounded())
            while written < target {
                let n = AVAudioFrameCount(min(16000, target - written))
                let zeros = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
                zeros.frameLength = n; memset(zeros.floatChannelData![0], 0, Int(n) * 4)
                try file.write(from: zeros); written += AVAudioFramePosition(n)
            }
            if written > target { input.framePosition = min(input.length, written - target) }
            while input.framePosition < input.length {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
                try input.read(into: buffer); if buffer.frameLength == 0 { break }; try file.write(from: buffer); written += AVAudioFramePosition(buffer.frameLength)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }
    /// Keep the contextual ASR text once; diarization only supplies a label.
    /// A roster is a sanity bound, not proof of the number or identity of voices.
    static func attribute(_ originals: [MeetingUtterance], segments: [Segment], participantCount: Int? = nil) -> [MeetingUtterance] {
        let labels = Set(segments.map { $0.speaker })
        let unstable = labels.count > max(1, participantCount ?? 8)
        return originals.map { original in
            var result = original
            result.speaker = "相手側（話者未確認）"
            guard !unstable else { return result }
            var overlap: [String: Double] = [:]
            for s in segments {
                let seconds = max(0, min(original.end, s.end) - max(original.start, s.start))
                if seconds > 0 { overlap[s.speaker, default: 0] += seconds }
            }
            let voices = overlap.filter { $0.value >= 0.5 }
            if voices.count == 1, let voice = voices.first, voice.value >= 1.5 {
                result.speaker = "相手側 \(voice.key)（氏名未確認）"
            } else if voices.count > 1 {
                result.speaker = "相手側（区間内に複数話者の可能性）"
            }
            return result
        }
    }

    static func transcribeSpeakers(chunks: [MeetingAudioCapture.Chunk], directory: URL, settings: Settings,
                                   originals: [MeetingUtterance], speakerCount: Int? = nil, participantCount: Int? = nil,
                                   cancelled: @escaping () -> Bool, progress: (String) -> Void) throws -> [MeetingUtterance] {
        guard !originals.isEmpty else { return [] }
        let remote = chunks.filter { $0.channel == .remote }
        guard !remote.isEmpty else { return originals }
        guard let helper, isAvailable else { throw MeetingFailure.message("話者分離モデルが未準備です。音声は保存済みです。") }
        let combined = directory.appendingPathComponent("remote-combined.wav")
        try combine(remote, output: combined)
        let output = directory.appendingPathComponent("speakers.json")
        progress("相手側の話者を確認中（本文は再分割しません）")
        var arguments = [helper.path, "--audio", combined.path, "--output", output.path, "--models", models.path]
        if let count = speakerCount, count > 0 { arguments += ["--speakers", String(count)] }
        _ = try Polisher.runCLI(path: python.path, arguments: arguments, timeout: .infinity, stage: "会議話者分離", cancelled: cancelled)
        let segments = try JSONDecoder().decode([Segment].self, from: Data(contentsOf: output))
        let source = try AVAudioFile(forReading: combined)
        let duration = Double(source.length) / source.fileFormat.sampleRate
        guard segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 0.2 && !$0.speaker.isEmpty }) else {
            throw MeetingFailure.message("話者分離の時刻が不正です。録音を保持しました。")
        }
        return attribute(originals, segments: segments, participantCount: participantCount)
    }
}
