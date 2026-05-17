import Foundation

public struct ChatTurn: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable {
        case user
        case assistant
    }

    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

public protocol LanguageModel: Sendable {
    func respond(history: [ChatTurn]) async throws -> String
    func stream(history: [ChatTurn]) -> AsyncThrowingStream<String, Error>
}

public extension LanguageModel {
    func stream(history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await respond(history: history)
                    try Task.checkCancellation()
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func respond(to prompt: String) async throws -> String {
        try await respond(history: [ChatTurn(role: .user, text: prompt)])
    }
}

public extension ChatTurn {
    init(_ message: ChatMessage) {
        let role: Role
        switch message.role {
        case .user: role = .user
        case .assistant: role = .assistant
        }
        self.init(role: role, text: message.text)
    }
}
