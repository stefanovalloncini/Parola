import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

public enum TranscriptChatProvider: Sendable, Hashable {
    case onDevice
    case cloud(CloudLLMProviderID)
}

public enum TranscriptChat {
    /// Chat on the on-device model. `digest` builds the summary a long transcript is condensed around
    /// when it has none saved; without one the session summarises it itself, for its own life only.
    public static func makeSession(
        transcript: Transcript,
        history: [ChatMessage] = [],
        budget: TokenBudget? = nil,
        digest: (@Sendable () async throws -> Summary)? = nil,
        features: FeatureSet = .resolve()
    ) async throws -> TranscriptChatSession {
        try features.require(.ai)
        let budget = budget ?? .onDevice
        return try await session(
            transcript: transcript,
            history: history,
            budget: budget,
            makeDigest: digestProvider(for: transcript, budget: budget, digest: digest),
            makeModel: { try await LanguageModelFactory.makeOnDevice(instructions: $0) }
        )
    }

    public static func makeSession(
        transcript: Transcript,
        history: [ChatMessage] = [],
        provider: TranscriptChatProvider,
        keyStore: APIKeyStore = KeychainAPIKeyStore.shared,
        managed: ManagedConfiguration = .shared,
        budget: TokenBudget? = nil,
        digest: (@Sendable () async throws -> Summary)? = nil,
        features: FeatureSet = .resolve()
    ) async throws -> TranscriptChatSession {
        try features.require(.ai)
        switch provider {
        case .onDevice:
            return try await makeSession(transcript: transcript, history: history, budget: budget, digest: digest, features: features)
        case .cloud(let id):
            return try await makeSession(
                transcript: transcript,
                history: history,
                budget: budget ?? .cloud(id),
                digest: digest,
                features: features,
                makeModel: { instructions in
                    try await LanguageModelFactory.makeBYOKCloud(
                        provider: id,
                        instructions: instructions,
                        keyStore: keyStore,
                        managed: managed
                    )
                }
            )
        }
    }

    /// Chat through a model the caller builds for the instructions it is handed. A transcript over
    /// `budget` is condensed the same way the on-device and cloud paths condense it.
    public static func makeSession(
        transcript: Transcript,
        history: [ChatMessage] = [],
        budget: TokenBudget,
        digest: (@Sendable () async throws -> Summary)? = nil,
        features: FeatureSet = .resolve(),
        makeModel: @escaping @Sendable (String) async throws -> any LanguageModel
    ) async throws -> TranscriptChatSession {
        try features.require(.ai)
        return try await session(
            transcript: transcript,
            history: history,
            budget: budget,
            makeDigest: digestProvider(for: transcript, budget: budget, digest: digest, summariseModel: {
                try await makeModel(SummaryService.textInstructions(for: SummaryOptions(actionItems: false)))
            }),
            makeModel: makeModel
        )
    }

    private static func session(
        transcript: Transcript,
        history: [ChatMessage],
        budget: TokenBudget,
        makeDigest: @escaping @Sendable () async throws -> Summary,
        makeModel: @escaping @Sendable (String) async throws -> any LanguageModel
    ) async throws -> TranscriptChatSession {
        if usesCondensedContext(for: transcript, budget: budget) {
            // Probe availability, key and policy now so an over-budget session fails at creation like the plain path.
            _ = try await makeModel("")
            let model = CondensedChatModel(transcript: transcript, budget: budget, makeDigest: makeDigest, makeModel: makeModel)
            return TranscriptChatSession(
                transcript: transcript, history: history, model: model, budget: budget,
                instructionTokens: budget.tokens - budget.condensedTurnTokens
            )
        }
        let instructions = systemInstructions(for: transcript)
        return TranscriptChatSession(
            transcript: transcript,
            history: history,
            model: try await makeModel(instructions),
            budget: budget,
            instructionTokens: budget.estimate(instructions)
        )
    }

    /// The system prompt a chat session runs with: the instructions plus the whole transcript,
    /// one timestamped line per segment. A caller that builds its own model needs these.
    public static func systemInstructions(for transcript: Transcript) -> String {
        systemInstructionsHeader + TranscriptPromptContext.timestampedLines(for: transcript)
    }

    private static let systemInstructionsHeader = """
        You answer questions about a transcript. Be concise — one or two sentences unless the user asks for more. When you reference a moment from the audio, include its timestamp in MM:SS or HH:MM:SS form.

        Transcript follows. Each line is prefixed with its timestamp.


        """

    /// Sized from the lines' lengths: a long transcript is condensed without ever building its full instructions.
    static func usesCondensedContext(for transcript: Transcript, budget: TokenBudget) -> Bool {
        let utf8Count = systemInstructionsHeader.utf8.count + TranscriptPromptContext.timestampedLinesUTF8Count(for: transcript)
        return budget.estimate(utf8Count: utf8Count) > budget.tokens
    }

    static func digestProvider(
        for transcript: Transcript,
        budget: TokenBudget,
        digest: (@Sendable () async throws -> Summary)? = nil,
        summariseModel: (@Sendable () async throws -> any LanguageModel)? = nil
    ) -> @Sendable () async throws -> Summary {
        if let summary = transcript.summary, !summary.text.isEmpty {
            return { summary }
        }
        if let digest { return digest }
        return {
            let service = SummaryService(budget: budget)
            if let summariseModel {
                return try await service.summarise(transcript, model: try await summariseModel())
            }
            return try await service.summarise(transcript)
        }
    }

    /// A transcript's segments with their keyword sets, so a condensed session tokenises once
    /// instead of once per question.
    struct KeywordIndex {
        let segments: [TranscriptSegment]
        let keywords: [Set<String>]

        init(_ transcript: Transcript) {
            segments = transcript.segments
            keywords = transcript.segments.map { TranscriptChat.keywordTokens($0.text) }
        }
    }

    static func condensedInstructions(
        for transcript: Transcript,
        question: String,
        digest: Summary,
        budget: TokenBudget
    ) -> String {
        condensedInstructions(
            for: KeywordIndex(transcript),
            question: question,
            digest: digest,
            budget: budget
        )
    }

    static func condensedInstructions(
        for index: KeywordIndex,
        question: String,
        digest: Summary,
        budget: TokenBudget
    ) -> String {
        var out = """
        You answer questions about a transcript. Be concise — one or two sentences unless the user asks for more. When you reference a moment from the audio, include its timestamp in MM:SS or HH:MM:SS form.

        The transcript is too long to include whole. Below are its summary and the excerpts most relevant to the latest question. Timestamps are from the original recording.

        SUMMARY:
        \(digest.text)
        """
        if !digest.chapters.isEmpty {
            out += "\n\nCHAPTERS:\n"
            for chapter in digest.chapters {
                out += "\(Timecode.format(chapter.start))  \(chapter.title)\n"
            }
        }
        out += "\nRELEVANT EXCERPTS:\n"
        let remaining = budget.tokens - budget.condensedTurnTokens - budget.estimate(out)
        for segment in relevantSegments(in: index, question: question, maxTokens: remaining, budget: budget) {
            let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            out += "\(Timecode.format(segment.start))  \(body)\n"
        }
        return out
    }

    static func relevantSegments(
        in transcript: Transcript,
        question: String,
        maxTokens: Int,
        budget: TokenBudget
    ) -> [TranscriptSegment] {
        relevantSegments(in: KeywordIndex(transcript), question: question, maxTokens: maxTokens, budget: budget)
    }

    static func relevantSegments(
        in index: KeywordIndex,
        question: String,
        maxTokens: Int,
        budget: TokenBudget
    ) -> [TranscriptSegment] {
        let questionTokens = keywordTokens(question)
        guard !questionTokens.isEmpty, maxTokens > 0 else { return [] }
        let ranked = zip(index.segments, index.keywords)
            .compactMap { segment, keywords -> (segment: TranscriptSegment, score: Int)? in
                let overlap = questionTokens.count { keywords.contains($0) }
                return overlap > 0 ? (segment, overlap) : nil
            }
            .sorted { $0.score == $1.score ? $0.segment.start < $1.segment.start : $0.score > $1.score }
        var left = maxTokens
        var picked: [TranscriptSegment] = []
        for (segment, _) in ranked {
            let cost = budget.estimate(segment.text) + 4
            guard cost <= left else { continue }
            left -= cost
            picked.append(segment)
        }
        return picked.sorted { $0.start < $1.start }
    }

    static func keywordTokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .filter { $0.count >= 3 }
                .map(String.init)
        )
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
struct FoundationLanguageModel: LanguageModel {
    private let instructions: String

    init(instructions: String) {
        self.instructions = instructions
    }

    func respond(history: [ChatTurn]) async throws -> String {
        let (session, prompt) = try makeSession(history: history)
        let r = try await session.respond(to: prompt)
        return r.content
    }

    func stream(history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (session, prompt) = try makeSession(history: history)
                    let response = session.streamResponse(to: prompt)
                    var emittedBytes = 0
                    for try await snapshot in response {
                        try Task.checkCancellation()
                        guard let delta = Self.delta(of: snapshot.content, after: emittedBytes) else { continue }
                        continuation.yield(delta.text)
                        emittedBytes = delta.bytes
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The text a snapshot added past the `emittedBytes` already sent, or nil when it added none; it assumes each snapshot extends the last.
    static func delta(of snapshot: String, after emittedBytes: Int) -> (text: String, bytes: Int)? {
        let bytes = snapshot.utf8.count
        guard bytes > emittedBytes,
              let text = String(snapshot.utf8.dropFirst(emittedBytes))
        else { return nil }
        return (text, bytes)
    }

    private func makeSession(history: [ChatTurn]) throws -> (LanguageModelSession, String) {
        guard let last = history.last, last.role == .user else {
            throw TranscriptChatSession.FailureReason.modelError(FixedFailureText.historyMustEndWithUserTurn)
        }
        var entries: [FoundationModels.Transcript.Entry] = []
        entries.append(.instructions(
            FoundationModels.Transcript.Instructions(
                segments: [.text(.init(content: instructions))],
                toolDefinitions: []
            )
        ))
        for turn in history.dropLast() {
            switch turn.role {
            case .user:
                entries.append(.prompt(
                    FoundationModels.Transcript.Prompt(segments: [.text(.init(content: turn.text))])
                ))
            case .assistant:
                entries.append(.response(
                    FoundationModels.Transcript.Response(assetIDs: [], segments: [.text(.init(content: turn.text))])
                ))
            }
        }
        let session = LanguageModelSession(transcript: FoundationModels.Transcript(entries: entries))
        return (session, last.text)
    }
}
#endif
