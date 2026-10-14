import Foundation

/// Bounded parallel correction. Nothing is returned until every sentence succeeds.
enum SentencePolisher {
    static func split(_ text: String) -> [String] {
        // Code blocks and inline code may contain punctuation that is not a sentence boundary.
        if text.contains("`") { return [text] }
        var sentences: [String] = [], current = "", closers: [Character] = []
        let brackets: [Character: Character] = ["「": "」", "『": "』", "（": "）", "(": ")", "[": "]", "【": "】", "\"": "\""]
        var pendingBoundary = false
        func flush() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { sentences.append(value) }
            current = ""; pendingBoundary = false
        }
        for c in text {
            if pendingBoundary && closers.isEmpty && !"。！？!?」』）)]】\"".contains(c) {
                flush()
            }
            current.append(c)
            if closers.last == c { closers.removeLast() }
            else if let close = brackets[c] { closers.append(close) }
            if "。！？".contains(c) && closers.isEmpty { pendingBoundary = true }
            if c == "\n" && closers.isEmpty { flush() }
        }
        flush()
        return sentences
    }

    static func map(_ sentences: [String], concurrency: Int = 3,
                    transform: @escaping (Int, String) throws -> String) throws -> [String] {
        guard !sentences.isEmpty else { return [] }
        final class State {
            let lock = NSLock()
            var next = 0
            var results: [String?]
            var error: Error?
            init(count: Int) { results = Array(repeating: nil, count: count) }
        }
        let state = State(count: sentences.count), group = DispatchGroup()
        for _ in 0..<min(max(1, concurrency), sentences.count) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                while true {
                    state.lock.lock()
                    guard state.error == nil, state.next < sentences.count else { state.lock.unlock(); return }
                    let index = state.next; state.next += 1
                    state.lock.unlock()
                    do {
                        let value = try transform(index, sentences[index])
                        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Polisher.PolishError.badResponse }
                        state.lock.lock(); state.results[index] = value; state.lock.unlock()
                    } catch {
                        state.lock.lock(); if state.error == nil { state.error = error }; state.lock.unlock()
                        return
                    }
                }
            }
        }
        group.wait()
        if let error = state.error { throw error }
        guard state.results.allSatisfy({ $0 != nil }) else { throw Polisher.PolishError.badResponse }
        return state.results.map { $0! }
    }

    static func polish(_ text: String, polisher: Polisher, context: ScreenContext?, client: ClientContext?,
                       aliases: [String: String], instructions: String, jevSettings: JevSettings = JevSettings(), progress: @escaping (Int, Int) -> Void = { _, _ in }) throws -> String {
        let sentences = split(text)
        let jev = IncrementalCorrection()
        defer { jev.cancel() }
        func advice(_ sentence: String, _ neighbors: String) -> String {
            jev.evaluate(text: sentence, segment: ClientDictionary.digest(sentence), revision: .init(asr: 1, context: 1),
                context: neighbors + "\n" + (context?.referenceText ?? ""), dictionary: client?.referenceText ?? "",
                screen: context?.vocabulary ?? [], meeting: false, settings: jevSettings).advice
        }
        guard text.count >= 120, sentences.count > 1 else {
            progress(0, 1)
            let value = try polisher.polish(text, context: context, client: client, aliases: aliases, instructions: instructions, neighboringSpeech: advice(text, ""))
            progress(1, 1)
            return value
        }
        let started = ProcessInfo.processInfo.systemUptime
        defer { Log.write(String(format: "文ごとの並列補正 %d文 %.2f秒", sentences.count, ProcessInfo.processInfo.systemUptime - started)) }
        let progressLock = NSLock()
        var completed = 0
        progress(0, sentences.count)
        let results = try map(sentences) { index, sentence in
            let before = index > 0 ? String(sentences[index - 1].suffix(400)) : ""
            let after = index + 1 < sentences.count ? String(sentences[index + 1].prefix(400)) : ""
            let value = try polisher.polish(sentence, context: context, client: client, aliases: aliases,
                                      instructions: instructions + "\nこれは長い発話の一文です。番号や箇条書き記号は保持し、前後の文を出力に混ぜないでください。",
                                      neighboringSpeech: "前の文: " + before + "\n次の文: " + after + "\n" + advice(sentence, before + "\n" + after))
            progressLock.lock(); completed += 1; progress(completed, sentences.count); progressLock.unlock()
            return value
        }
        return results.joined(separator: "\n")
    }
}
