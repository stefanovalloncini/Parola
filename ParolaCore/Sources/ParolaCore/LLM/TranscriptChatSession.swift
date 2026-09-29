import Foundation

public actor TranscriptChatSession {
    public enum FailureReason: LocalizedError, CustomStringConvertible, Sendable {
        case notAvailable(String)
        case modelError(String)

        public var description: String {
            switch self {
            case .notAvailable(let reason): return "Chat unavailable: \(reason)"
            case .modelError(let reason): return "Chat failed: \(reason)"
            }
        }

        public var errorDescription: String? { description }
    }

    public enum StreamEvent: Sendable {
        case delta(String)
        case completed(ChatMessage)
    }

    private let model: any LanguageModel
    public let transcript: Transcript
    public private(set) var history: [ChatMessage]
    private var inFlight: Task<Void, Never>?
    private let budget: TokenBudget?
    /// Tokens the replayed turns and the new message may take together; nil replays every turn.
    private let turnRoom: Int?

    /// Characters the next message may use, attachments included, while recent turns keep room; nil when unbounded.
    public nonisolated let messageCharacterLimit: Int?

    /// With a `budget`, only the most recent turns that fit beside instructions of `instructionTokens` are replayed.
    public init(
        transcript: Transcript,
        history: [ChatMessage] = [],
        model: any LanguageModel,
        budget: TokenBudget? = nil,
        instructionTokens: Int = 0
    ) {
        self.transcript = transcript
        self.history = history
        self.model = model
        self.budget = budget
        if let budget {
            let answer = min(1024, budget.answerTokens / 2)
            let room = max(1, budget.contextTokens - instructionTokens - answer)
            turnRoom = room
            messageCharacterLimit = budget.characters(forTokens: room / 2)
        } else {
            turnRoom = nil
            messageCharacterLimit = nil
        }
    }

    /// The newest turns that fit the room left beside the new message, starting on a question.
    func turns(for message: ChatMessage) -> [ChatTurn] {
        let user = ChatTurn(message)
        guard let turnRoom, let budget else { return history.map(ChatTurn.init) + [user] }
        var left = turnRoom - budget.estimate(message.text) - 4
        var kept: [ChatTurn] = []
        for turn in history.reversed() {
            let cost = budget.estimate(turn.text) + 4
            guard cost <= left else { break }
            left -= cost
            kept.append(ChatTurn(turn))
        }
        kept.reverse()
        while kept.first?.role == .assistant { kept.removeFirst() }
        return kept + [user]
    }

    public func ask(_ message: String) async throws -> ChatMessage {
        let prior = inFlight
        let work = Task { () async throws -> ChatMessage in
            await prior?.value
            return try await self.performAsk(message)
        }
        inFlight = Task { _ = try? await work.value }
        // The unstructured serial task does not inherit the caller's cancellation; forward it,
        // or an abandoned generation runs to completion and pollutes history.
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func performAsk(_ message: String) async throws -> ChatMessage {
        try Task.checkCancellation()
        let user = ChatMessage(role: .user, text: message)
        let turns = turns(for: user)
        let raw: String
        do {
            do {
                raw = try await model.respond(history: turns)
            } catch where turns.count > 1 && LanguageModelFactory.isContextOverflow(error) {
                raw = try await model.respond(history: [ChatTurn(user)])
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FailureReason.modelError(error.localizedDescription)
        }
        try Task.checkCancellation()
        let assistant = ChatMessage(
            role: .assistant,
            text: raw.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        history.append(user)
        history.append(assistant)
        return assistant
    }

    public nonisolated func stream(_ message: String) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                await self.runSerialStream(message: message, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func clearHistory() {
        history = []
    }

    private func runSerialStream(
        message: String,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async {
        let prior = inFlight
        let current = Task { [self] in
            await prior?.value
            await self.runStreamBody(message: message, continuation: continuation)
        }
        inFlight = current
        // Same forwarding as ask(): the serial task won't see the stream's termination otherwise.
        await withTaskCancellationHandler {
            await current.value
        } onCancel: {
            current.cancel()
        }
    }

    private func runStreamBody(
        message: String,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async {
        do {
            try Task.checkCancellation()
            let user = ChatMessage(role: .user, text: message)
            let turns = turns(for: user)
            var collected = ""
            do {
                for try await delta in model.stream(history: turns) {
                    try Task.checkCancellation()
                    collected += delta
                    continuation.yield(.delta(delta))
                }
            } catch where collected.isEmpty && turns.count > 1 && LanguageModelFactory.isContextOverflow(error) {
                for try await delta in model.stream(history: [ChatTurn(user)]) {
                    try Task.checkCancellation()
                    collected += delta
                    continuation.yield(.delta(delta))
                }
            }
            // A cancelled model stream can end without throwing; don't record the partial turn.
            try Task.checkCancellation()
            let assistant = ChatMessage(
                role: .assistant,
                text: collected.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            history.append(user)
            history.append(assistant)
            continuation.yield(.completed(assistant))
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
        } catch {
            continuation.finish(throwing: FailureReason.modelError(error.localizedDescription))
        }
    }
}
