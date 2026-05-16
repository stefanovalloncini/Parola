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

    private let model: any LanguageModel
    public let transcript: Transcript
    public private(set) var history: [ChatMessage]

    public init(transcript: Transcript, history: [ChatMessage] = [], model: any LanguageModel) {
        self.transcript = transcript
        self.history = history
        self.model = model
    }

    public func ask(_ message: String) async throws -> ChatMessage {
        let user = ChatMessage(role: .user, text: message)
        history.append(user)
        do {
            let raw = try await model.respond(to: message)
            let assistant = ChatMessage(
                role: .assistant,
                text: raw.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            history.append(assistant)
            return assistant
        } catch {
            throw FailureReason.modelError(error.localizedDescription)
        }
    }

    public func clearHistory() {
        history = []
    }
}
