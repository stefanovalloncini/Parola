import Foundation

public struct MockLanguageModelFailure: Sendable {
    public enum Code: String, Sendable {
        case notAvailable
        case modelError
        case missingAPIKey
        case disabledByPolicy
    }

    public var code: Code
    public var message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }

    func asError() -> Error {
        switch code {
        case .notAvailable:
            return LanguageModelFactory.Failure.notAvailable(message)
        case .modelError:
            return CloudLLMError.malformedResponse(provider: .openAI)
        case .missingAPIKey:
            return CloudLLMError.missingAPIKey(.openAI)
        case .disabledByPolicy:
            return CloudLLMError.disabledByPolicy
        }
    }
}

public struct MockLanguageModelResponse: Sendable {
    public var text: String
    public var streamChunks: [String]?
    public var delayMs: Int
    public var failure: MockLanguageModelFailure?

    public init(
        text: String = "",
        streamChunks: [String]? = nil,
        delayMs: Int = 0,
        failure: MockLanguageModelFailure? = nil
    ) {
        self.text = text
        self.streamChunks = streamChunks
        self.delayMs = delayMs
        self.failure = failure
    }
}

public struct MockLanguageModel: LanguageModel {
    let response: MockLanguageModelResponse
    let sleeper: @Sendable (Int) async throws -> Void

    public init<C: Clock>(response: MockLanguageModelResponse, clock: C) where C.Duration == Duration {
        self.response = response
        self.sleeper = { ms in
            try await Task.sleep(for: .milliseconds(ms), clock: clock)
        }
    }

    public static func make(response: MockLanguageModelResponse, clock: any Clock<Duration>) -> MockLanguageModel {
        func _make<C: Clock>(_ clock: C) -> MockLanguageModel where C.Duration == Duration {
            MockLanguageModel(response: response, clock: clock)
        }
        return _make(clock)
    }

    public func respond(history: [ChatTurn]) async throws -> String {
        if let failure = response.failure {
            if response.delayMs > 0 {
                try? await sleeper(response.delayMs)
            }
            throw failure.asError()
        }
        if response.delayMs > 0 {
            try? await sleeper(response.delayMs)
        }
        return response.text
    }

    public func stream(history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        let response = response
        let sleeper = sleeper
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let failure = response.failure {
                    if response.delayMs > 0 {
                        try? await sleeper(response.delayMs)
                    }
                    continuation.finish(throwing: failure.asError())
                    return
                }
                let chunks = response.streamChunks ?? [response.text]
                let perStepMs = chunks.isEmpty ? 0 : response.delayMs / max(1, chunks.count)
                for chunk in chunks {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    continuation.yield(chunk)
                    if perStepMs > 0 {
                        try? await sleeper(perStepMs)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
