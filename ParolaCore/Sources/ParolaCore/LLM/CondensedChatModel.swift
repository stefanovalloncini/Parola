import Foundation

actor CondensedChatModel: LanguageModel {
    private let transcript: Transcript
    /// Built at the first question, on this actor, rather than wherever the session was made.
    private var index: TranscriptChat.KeywordIndex?
    private let budget: TokenBudget
    private let makeDigest: @Sendable () async throws -> Summary
    private let makeModel: @Sendable (String) async throws -> any LanguageModel
    private var digest: Summary?

    init(
        transcript: Transcript,
        budget: TokenBudget,
        makeDigest: @escaping @Sendable () async throws -> Summary,
        makeModel: @escaping @Sendable (String) async throws -> any LanguageModel
    ) {
        self.transcript = transcript
        self.budget = budget
        self.makeDigest = makeDigest
        self.makeModel = makeModel
    }

    func respond(history: [ChatTurn]) async throws -> String {
        try await model(for: history).respond(history: history)
    }

    nonisolated func stream(history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let inner = try await self.model(for: history)
                    for try await chunk in inner.stream(history: history) {
                        try Task.checkCancellation()
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func model(for history: [ChatTurn]) async throws -> any LanguageModel {
        let question = history.last(where: { $0.role == .user })?.text ?? ""
        let index = keywordIndex()
        let instructions = TranscriptChat.condensedInstructions(
            for: index,
            question: question,
            digest: try await cachedDigest(),
            budget: budget
        )
        return try await makeModel(instructions)
    }

    private func keywordIndex() -> TranscriptChat.KeywordIndex {
        if let index { return index }
        let built = TranscriptChat.KeywordIndex(transcript)
        index = built
        return built
    }

    private func cachedDigest() async throws -> Summary {
        if let digest { return digest }
        let built = try await makeDigest()
        digest = built
        return built
    }
}
