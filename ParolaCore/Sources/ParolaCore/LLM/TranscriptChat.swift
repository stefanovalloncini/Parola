import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

public enum TranscriptChatProvider: Sendable, Hashable {
    case onDevice
    case cloud(CloudLLMProviderID)
}

public enum TranscriptChat {
    public static let defaultBudgetTokens = 3500

    public static func makeSession(
        transcript: Transcript,
        history: [ChatMessage] = [],
        budgetTokens: Int? = nil,
        features: FeatureSet = .resolve()
    ) throws -> TranscriptChatSession {
        try features.require(.ai)
        let budget = budgetTokens ?? defaultBudgetTokens
        let instructions = systemInstructions(for: transcript)
        let model: any LanguageModel
        if usesCondensedContext(instructions: instructions, budgetTokens: budget) {
            // Probe availability now so an over-budget session fails at creation like the plain path.
            _ = try makeOnDeviceModel(instructions: "")
            model = CondensedChatModel(
                transcript: transcript,
                budgetTokens: budget,
                makeDigest: digestProvider(for: transcript, budgetTokens: budget),
                makeModel: { try makeOnDeviceModel(instructions: $0) }
            )
        } else {
            model = try makeOnDeviceModel(instructions: instructions)
        }
        return TranscriptChatSession(transcript: transcript, history: history, model: model)
    }

    public static func makeSession(
        transcript: Transcript,
        history: [ChatMessage] = [],
        provider: TranscriptChatProvider,
        keyStore: APIKeyStore = KeychainAPIKeyStore.shared,
        managed: ManagedConfiguration = .shared,
        budgetTokens: Int? = nil,
        features: FeatureSet = .resolve()
    ) async throws -> TranscriptChatSession {
        try features.require(.ai)
        switch provider {
        case .onDevice:
            return try makeSession(transcript: transcript, history: history, budgetTokens: budgetTokens, features: features)
        case .cloud(let id):
            let budget = budgetTokens ?? cloudBudgetTokens(for: id)
            let makeCloudModel: @Sendable (String) async throws -> any LanguageModel = { instructions in
                try await LanguageModelFactory.makeBYOKCloud(
                    provider: id,
                    instructions: instructions,
                    keyStore: keyStore,
                    managed: managed
                )
            }
            let instructions = systemInstructions(for: transcript)
            let model: any LanguageModel
            if usesCondensedContext(instructions: instructions, budgetTokens: budget) {
                // Probe key/policy now so an over-budget session fails at creation like the plain path.
                _ = try await makeCloudModel("")
                model = CondensedChatModel(
                    transcript: transcript,
                    budgetTokens: budget,
                    makeDigest: digestProvider(for: transcript, budgetTokens: budget, summariseModel: {
                        try await makeCloudModel(SummaryService.textInstructions(for: .default))
                    }),
                    makeModel: makeCloudModel
                )
            } else {
                model = try await makeCloudModel(instructions)
            }
            return TranscriptChatSession(transcript: transcript, history: history, model: model)
        }
    }

    public static func makeSession(
        transcript: Transcript,
        history: [ChatMessage] = [],
        model: any LanguageModel
    ) -> TranscriptChatSession {
        TranscriptChatSession(transcript: transcript, history: history, model: model)
    }

    static func systemInstructions(for transcript: Transcript) -> String {
        var out = """
        You answer questions about a transcript. Be concise — one or two sentences unless the user asks for more. When you reference a moment from the audio, include its timestamp in MM:SS or HH:MM:SS form.

        Transcript follows. Each line is prefixed with its timestamp.


        """
        out += TranscriptPromptContext.timestampedLines(for: transcript)
        return out
    }

    static func usesCondensedContext(instructions: String, budgetTokens: Int) -> Bool {
        TokenBudget.estimateTokens(instructions) > budgetTokens
    }

    static func usesCondensedContext(for transcript: Transcript, budgetTokens: Int) -> Bool {
        usesCondensedContext(instructions: systemInstructions(for: transcript), budgetTokens: budgetTokens)
    }

    static func cloudBudgetTokens(for id: CloudLLMProviderID, responseHeadroom: Int = 4096) -> Int {
        guard let info = CloudLLMProviderInfo.info(for: id) else { return defaultBudgetTokens }
        return max(defaultBudgetTokens, info.contextWindowTokens - responseHeadroom)
    }

    static func digestProvider(
        for transcript: Transcript,
        budgetTokens: Int,
        summariseModel: (@Sendable () async throws -> any LanguageModel)? = nil
    ) -> @Sendable () async throws -> Summary {
        if let summary = transcript.summary, !summary.text.isEmpty {
            return { summary }
        }
        return {
            let service = SummaryService(budgetTokens: budgetTokens)
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
        budgetTokens: Int
    ) -> String {
        condensedInstructions(
            for: KeywordIndex(transcript),
            question: question,
            digest: digest,
            budgetTokens: budgetTokens
        )
    }

    static func condensedInstructions(
        for index: KeywordIndex,
        question: String,
        digest: Summary,
        budgetTokens: Int
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
        let remaining = budgetTokens - TokenBudget.estimateTokens(out)
        for segment in relevantSegments(in: index, question: question, maxTokens: remaining) {
            let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            out += "\(Timecode.format(segment.start))  \(body)\n"
        }
        return out
    }

    static func relevantSegments(
        in transcript: Transcript,
        question: String,
        maxTokens: Int
    ) -> [TranscriptSegment] {
        relevantSegments(in: KeywordIndex(transcript), question: question, maxTokens: maxTokens)
    }

    static func relevantSegments(
        in index: KeywordIndex,
        question: String,
        maxTokens: Int
    ) -> [TranscriptSegment] {
        let questionTokens = keywordTokens(question)
        guard !questionTokens.isEmpty, maxTokens > 0 else { return [] }
        let ranked = zip(index.segments, index.keywords)
            .compactMap { segment, keywords -> (segment: TranscriptSegment, score: Int)? in
                let overlap = questionTokens.count { keywords.contains($0) }
                return overlap > 0 ? (segment, overlap) : nil
            }
            .sorted { $0.score == $1.score ? $0.segment.start < $1.segment.start : $0.score > $1.score }
        var budget = maxTokens
        var picked: [TranscriptSegment] = []
        for (segment, _) in ranked {
            let cost = TokenBudget.estimateTokens(segment.text) + 4
            guard cost <= budget else { continue }
            budget -= cost
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

    private static func makeOnDeviceModel(instructions: String) throws -> any LanguageModel {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return FoundationLanguageModel(instructions: instructions)
            case .unavailable(let reason):
                throw TranscriptChatSession.FailureReason.notAvailable(LanguageModelFactory.unavailableMessage(for: reason))
            @unknown default:
                throw TranscriptChatSession.FailureReason.notAvailable("Apple Intelligence isn't available right now.")
            }
        }
        #endif
        throw TranscriptChatSession.FailureReason.notAvailable("Apple Intelligence needs macOS 26 or iOS 26 or newer.")
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
                    var lastEmitted = ""
                    for try await snapshot in response {
                        try Task.checkCancellation()
                        let current = snapshot.content
                        guard current.count >= lastEmitted.count else { continue }
                        let delta = String(current.dropFirst(lastEmitted.count))
                        if !delta.isEmpty {
                            continuation.yield(delta)
                            lastEmitted = current
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeSession(history: [ChatTurn]) throws -> (LanguageModelSession, String) {
        guard let last = history.last, last.role == .user else {
            throw TranscriptChatSession.FailureReason.modelError("History must end with a user turn.")
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
