import Foundation

/// Partitions PCM at sustained quiet boundaries, without dropping or overlapping frames.
struct SpeechSegments {
    private var pending: [Float] = []
    private var segment: [Float] = []
    private var quietFrames = 0
    mutating func append(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        var output: [[Float]] = []
        while pending.count >= 320 {
            let block = Array(pending.prefix(320)); pending.removeFirst(320)
            segment.append(contentsOf: block)
            let peak = block.map { abs($0) }.max() ?? 0
            let rms = sqrt(block.reduce(0.0) { $0 + Double($1 * $1) } / 320)
            quietFrames = peak < 0.015 && rms < 0.003 ? quietFrames + 320 : 0
            if segment.count >= 32000 && quietFrames >= 3200 {
                output.append(segment); segment.removeAll(keepingCapacity: true); quietFrames = 0
            }
        }
        return output
    }
    var sampleCount: Int { segment.count + pending.count }
    var snapshot: [Float] { segment + pending }
    mutating func finish() -> [Float] {
        segment.append(contentsOf: pending)
        let tail = segment
        pending.removeAll(); segment.removeAll(); quietFrames = 0
        return tail
    }
    static func containsVoice(_ samples: [Float]) -> Bool {
        samples.contains { abs($0) >= 0.015 }
    }
    static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        text("RIFF"); number(UInt32(36 + samples.count * 2)); text("WAVEfmt ")
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(16000))
        number(UInt32(32000)); number(UInt16(2)); number(UInt16(16)); text("data")
        number(UInt32(samples.count * 2))
        for sample in samples { number(Int16(max(-32768, min(32767, Double(sample) * 32767)))) }
        return data
    }
}

/// Reuses correction only when the target sentence AND its neighbors match the final text exactly.
final class EarlyPolisher {
    struct Plan { let text: String; let neighbors: String; var key: String { ClientDictionary.digest(text + "\u{0}" + neighbors) } }
    final class Job {
        let group = DispatchGroup()
        let lock = NSLock()
        private var cancelled = false
        var result: Result<String, Error>?
        init() { group.enter() }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }
    private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 2; q.qualityOfService = .userInitiated; return q }()
    private let jobsLock = NSRecursiveLock()
    private var stopped = false
    private var jobs: [String: Job] = [:] // accessed from the serial recognition queue, then from finish only
    private let correction: (String, String, @escaping () -> Bool) throws -> String
    init(correction: @escaping (String, String, @escaping () -> Bool) throws -> String) { self.correction = correction }
    static func plans(_ text: String) -> [Plan] {
        let sentences = SentencePolisher.split(text)
        if sentences.count < 2 { return [Plan(text: text, neighbors: "")] }
        return sentences.enumerated().map { index, sentence in
            Plan(text: sentence, neighbors: "前の文: " + (index > 0 ? String(sentences[index - 1].suffix(400)) : "")
                 + "\n次の文: " + (index + 1 < sentences.count ? String(sentences[index + 1].prefix(400)) : ""))
        }
    }
    private func get(_ plan: Plan) -> Job {
        jobsLock.lock(); defer { jobsLock.unlock() }
        if let existing = jobs[plan.key] { return existing }
        let job = Job(); jobs[plan.key] = job
        if stopped { job.cancel() }
        let correct = correction
        queue.addOperation {
            defer { job.group.leave() }
            job.result = Result {
                guard !job.isCancelled else { throw Polisher.PolishError.cancelled }
                return try correct(plan.text, plan.neighbors, { job.isCancelled })
            }
        }
        return job
    }
    func offer(_ text: String) {
        let plans = Self.plans(text)
        // Speculate even on a short first sentence. Reuse requires exact text AND neighbors.
        let needed = Set(plans.map(\.key))
        jobsLock.lock()
        for key in Array(jobs.keys) where !needed.contains(key) {
            jobs.removeValue(forKey: key)?.cancel()
        }
        jobsLock.unlock()
        for plan in plans { _ = get(plan) }
    }
    func finish(_ text: String, progress: (Int, Int) -> Void) throws -> String {
        let plans = Self.plans(text)
        let needed = Set(plans.map(\.key))
        jobsLock.lock()
        for (key, job) in jobs where !needed.contains(key) { job.cancel() }
        let reused = plans.filter { jobs[$0.key] != nil }.count
        jobsLock.unlock()
        let chosen = plans.map { get($0) }
        Log.write("録音中のAI準備を再利用 \(reused)/\(plans.count)文")
        var reported = -1
        while true {
            let complete = chosen.filter { $0.group.wait(timeout: .now()) == .success }
            for job in complete { if case .failure(let error) = job.result { throw error } }
            if complete.count != reported { reported = complete.count; progress(reported, chosen.count) }
            if complete.count == chosen.count { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return try chosen.map { try $0.result!.get() }.joined(separator: "\n")
    }
    func cancel() { jobsLock.lock(); stopped = true; for job in jobs.values { job.cancel() }; jobsLock.unlock() }
}

final class LiveDictation {
    private let inputQueue = DispatchQueue(label: "voice.live.samples")
    private let recognitionQueue = DispatchQueue(label: "voice.live.recognition", qos: .userInitiated)
    private var segments = SpeechSegments()
    private var rawParts: [String] = []
    private var failure: Error?
    private var stopped = false
    private let flag = NSLock()
    private var cancelled = false
    private var temporaryFiles: Set<URL> = []
    private let settings: Settings
    private let preparation: ReferencePreparation?
    private let initialContext: ScreenContext?
    private let screenPreparation: ScreenPreparation?
    private var context: ScreenContext? { screenPreparation?.wait() ?? initialContext }
    private let terms = TermDictionary.load()
    private let jev = IncrementalCorrection()
    private let allowsAI: Bool
    private let earlyLock = NSLock()
    private var earlyStorage: EarlyPolisher?
    private var early: EarlyPolisher? {
        get { earlyLock.lock(); defer { earlyLock.unlock() }; return earlyStorage }
        set { earlyLock.lock(); earlyStorage = newValue; earlyLock.unlock() }
    }
    private var completedChunks = 0
    private var nextChunk = 0
    // One speculative ASR at a time; no growing preview queue.
    private var previewInFlight = false // inputQueue only
    private var previewAt = 0
    private var preview: (index: Int, samples: [Float], text: String)? // recognitionQueue only
    static func reusablePreview(_ samples: [Float], final: [Float]) -> Bool {
        final.count >= samples.count && final.starts(with: samples)
            && final.dropFirst(samples.count).allSatisfy { abs($0) < 0.003 }
    }
    init(settings: Settings, preparation: ReferencePreparation?, context: ScreenContext?, allowsAI: Bool = true, screenPreparation: ScreenPreparation? = nil) {
        self.allowsAI = allowsAI
        self.settings = settings; self.preparation = preparation; self.initialContext = context
        self.screenPreparation = screenPreparation
    }
    private var isCancelled: Bool { flag.lock(); defer { flag.unlock() }; return cancelled }
    private func writeAudio(_ samples: [Float], to url: URL) throws {
        let data = SpeechSegments.wav(samples)
        flag.lock(); defer { flag.unlock() }
        guard !cancelled else { throw Polisher.PolishError.cancelled }
        try data.write(to: url, options: .atomic)
        temporaryFiles.insert(url)
    }
    private func removeAudio(_ url: URL) {
        flag.lock(); temporaryFiles.remove(url); flag.unlock()
        try? FileManager.default.removeItem(at: url)
    }
    private func formatter() -> Formatter {
        Formatter(terms: terms, forbiddenWords: StyleWords.load(from: settings.styleWordsPath),
                  dropSelfCorrections: settings.dropSelfCorrections, spaceAroundLatin: settings.spaceAroundLatin,
                  trimTrailingPeriod: settings.trimTrailingPeriod)
    }
    func append(_ samples: [Float]) {
        inputQueue.async {
            guard !self.stopped, !self.isCancelled else { return }
            let chunks = self.segments.append(samples)
            for chunk in chunks { self.submit(chunk); self.previewAt = 0 }
            let count = self.segments.sampleCount
            if !self.previewInFlight && count >= 64000 && count - self.previewAt >= 64000 && count <= 384000 {
                self.previewInFlight = true; self.previewAt = count
                self.submit(self.segments.snapshot, provisional: true)
            }
        }
    }
    private func submit(_ samples: [Float], provisional: Bool = false) {
        guard !samples.isEmpty else { return }
        let index = nextChunk + 1
        if !provisional { nextChunk += 1 }
        recognitionQueue.async {
            defer { if provisional { self.inputQueue.async { self.previewInFlight = false } } }
            guard !self.isCancelled, self.failure == nil, SpeechSegments.containsVoice(samples) else { return }
            let url = Paths.tmp.appendingPathComponent("live-\(UUID().uuidString).wav")
            defer { self.removeAudio(url) }
            do {
                let client = self.preparation?.wait()
                let aliases = self.settings.clientNameAliases[self.settings.selectedClientFolder] ?? [:]
                let hint = client?.initialPrompt(dictionary: self.terms.initialPrompt, screen: self.context, aliases: aliases)
                    ?? self.context?.initialPrompt(dictionary: self.terms.initialPrompt) ?? self.terms.initialPrompt
                guard let whisper = self.settings.resolvedWhisper else { throw Transcriber.TranscribeError.whisperMissing }
                let text: String
                if !provisional, let preview = self.preview, preview.index == index,
                   Self.reusablePreview(preview.samples, final: samples) {
                    text = preview.text
                    Log.write("途中認識を再利用 区間\(index)")
                } else {
                    try self.writeAudio(samples, to: url)
                    text = try Transcriber(whisperPath: whisper, modelPath: self.settings.resolvedModel,
                        language: self.settings.language, initialPrompt: hint, fastMode: !self.settings.polishWithClaude, useMLX: self.settings.mlxForDictation).transcribe(url)
                }
                guard !text.isEmpty, !Hallucination.isOnly(text) else { throw Polisher.PolishError.badResponse }
                if self.isCancelled { return }
                let draft: String
                if provisional {
                    self.preview = (index, samples, text)
                    draft = (self.rawParts + [text]).joined(separator: " ")
                } else {
                    self.rawParts.append(text); self.completedChunks += 1; self.preview = nil
                    draft = self.rawParts.joined(separator: " ")
                }
                Log.write("録音中文字起こし 区間\(index) \(provisional ? "仮認識" : "確定")（\(samples.count)フレーム）")
                if self.settings.polishWithClaude && self.allowsAI && (self.settings.selectedClientFolder.isEmpty || (client != nil && client?.unavailable == false)) {
                    if self.early == nil {
                        let settings = self.settings
                        let screen = settings.shareScreenContextWithClaude ? self.context : nil
                        let jev = self.jev
                        self.early = EarlyPolisher { text, neighbors, cancelled in
                            let decision = jev.evaluate(text: text, segment: ClientDictionary.digest(text), revision: .init(asr: 1, context: 1), context: neighbors + "\n" + (screen?.referenceText ?? ""), dictionary: client?.referenceText ?? "", screen: screen?.vocabulary ?? [], meeting: false, settings: settings.jev, cancelled: cancelled)
                            if !decision.needsClaude { return decision.text }
                            return try Polisher(model: settings.polishModel, effort: settings.polishEffort).polish(text,
                                context: screen, client: client, aliases: aliases, instructions: settings.customPolishInstructions,
                                neighboringSpeech: neighbors + "\n" + decision.advice, cancelled: cancelled)
                        }
                    }
                    self.early?.offer(self.formatter().format(draft).text)
                }
            } catch { if !provisional { self.failure = error } }
        }
    }
    func finish() throws -> String {
        inputQueue.sync {
            guard !stopped else { return }
            stopped = true
            submit(segments.finish())
        }
        return try recognitionQueue.sync {
            if let failure { throw failure }
            return rawParts.joined(separator: " ")
        }
    }
    func polish(_ text: String, client: ClientContext?, progress: @escaping (Int, Int) -> Void) throws -> String {
        // finish() has drained recognition before this call, so the cache is no longer being mutated.
        if early == nil {
            let settings = self.settings
            let screen = settings.shareScreenContextWithClaude ? context : nil
            let aliases = settings.clientNameAliases[settings.selectedClientFolder] ?? [:]
            let jev = self.jev
            early = EarlyPolisher { text, neighbors, cancelled in
                let decision = jev.evaluate(text: text, segment: ClientDictionary.digest(text), revision: .init(asr: 1, context: 1), context: neighbors + "\n" + (screen?.referenceText ?? ""), dictionary: client?.referenceText ?? "", screen: screen?.vocabulary ?? [], meeting: false, settings: settings.jev, cancelled: cancelled)
                if !decision.needsClaude { return decision.text }
                return try Polisher(model: settings.polishModel, effort: settings.polishEffort).polish(text,
                    context: screen, client: client, aliases: aliases, instructions: settings.customPolishInstructions,
                    neighboringSpeech: neighbors + "\n" + decision.advice, cancelled: cancelled)
            }
        }
        guard !isCancelled else { early?.cancel(); throw Polisher.PolishError.cancelled }
        return try early!.finish(text, progress: progress)
    }
    func cancel() {
        jev.cancel()
        flag.lock(); cancelled = true; let files = temporaryFiles; temporaryFiles.removeAll(); flag.unlock()
        for url in files { try? FileManager.default.removeItem(at: url) }
        early?.cancel()
        inputQueue.async { self.stopped = true; _ = self.segments.finish() }
        recognitionQueue.async { self.early?.cancel(); self.early = nil; self.rawParts.removeAll() }
    }
}
