import Foundation
@testable import ParolaCore

actor MockLanguageModel: LanguageModel {
    var scriptedResponses: [String]
    var scriptedError: Error?
    private(set) var receivedHistories: [[ChatTurn]] = []

    init(scriptedResponses: [String] = [], error: Error? = nil) {
        self.scriptedResponses = scriptedResponses
        self.scriptedError = error
    }

    func setError(_ error: Error?) {
        self.scriptedError = error
    }

    func enqueue(_ response: String) {
        scriptedResponses.append(response)
    }

    private func record(_ history: [ChatTurn]) {
        receivedHistories.append(history)
    }

    private func nextResponse() throws -> String {
        if let scriptedError { throw scriptedError }
        guard !scriptedResponses.isEmpty else { return "" }
        return scriptedResponses.removeFirst()
    }

    func respond(history: [ChatTurn]) async throws -> String {
        record(history)
        return try nextResponse()
    }

    nonisolated func stream(history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    await record(history)
                    let full = try await nextResponse()
                    for character in full {
                        try Task.checkCancellation()
                        continuation.yield(String(character))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    var lastReceivedHistory: [ChatTurn]? { receivedHistories.last }
    var receivedPrompts: [String] { receivedHistories.compactMap { $0.last?.text } }
    var lastReceivedTexts: [String] { lastReceivedHistory?.map(\.text) ?? [] }
}
