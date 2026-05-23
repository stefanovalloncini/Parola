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

    public init(transcript: Transcript, history: [ChatMessage] = [], model: any LanguageModel) {
        self.transcript = transcript
        self.history = history
        self.model = model
    }

    public func ask(_ message: String) async throws -> ChatMessage {
        let user = ChatMessage(role: .user, text: message)
        let turns = (history + [user]).map(ChatTurn.init)
        let raw: String
        do {
            raw = try await model.respond(history: turns)
        } catch {
            throw FailureReason.modelError(error.localizedDescription)
        }
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
        await current.value
    }

    private func runStreamBody(
        message: String,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async {
        do {
            try Task.checkCancellation()
            let user = ChatMessage(role: .user, text: message)
            let turns = (history + [user]).map(ChatTurn.init)
            var collected = ""
            for try await delta in model.stream(history: turns) {
                try Task.checkCancellation()
                collected += delta
                continuation.yield(.delta(delta))
            }
            let assistant = ChatMessage(
                role: .assistant,
                text: collected.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            history.append(user)
            history.append(assistant)
            continuation.yield(.completed(assistant))
            continuation.finish()
        } catch {
            continuation.finish(throwing: FailureReason.modelError(error.localizedDescription))
        }
    }
}
