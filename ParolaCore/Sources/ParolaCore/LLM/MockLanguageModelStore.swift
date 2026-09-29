import Foundation

public actor MockLanguageModelStore {
    public static let shared = MockLanguageModelStore()

    public enum Provider: String, Sendable, Hashable {
        case openAI
        case anthropic
        case groq
        case cerebras
        case ollama
        case foundation
        case custom
    }

    private var byProvider: [Provider: MockLanguageModelResponse] = [:]
    private var globalMock: MockLanguageModelResponse?
    private var lastInstructions: [Provider: String] = [:]
    private var lastPrompts: [Provider: String] = [:]
    private var leased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Runs `body` with exclusive use of this store. The slots are process-global while
    /// swift-testing runs suites in parallel, so two suites installing at once would resolve each
    /// other's mocks; lessees are served first come, first served, and a throwing body still releases.
    public func withLease<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        guard leased else {
            leased = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            leased = false
            return
        }
        waiters.removeFirst().resume()
    }

    public func install(provider: Provider?, response: MockLanguageModelResponse) {
        if let provider {
            byProvider[provider] = response
        } else {
            globalMock = response
        }
    }

    public func clear() {
        byProvider.removeAll()
        globalMock = nil
        lastInstructions.removeAll()
        lastPrompts.removeAll()
    }

    public func resolve(for provider: Provider) -> MockLanguageModelResponse? {
        byProvider[provider] ?? globalMock
    }

    /// Callers that route to a mock instead of the real model record the instructions they were given here, so a test can assert on them.
    public func recordInstructions(_ instructions: String, for provider: Provider) {
        lastInstructions[provider] = instructions
    }

    public func lastInstructions(for provider: Provider) -> String? {
        lastInstructions[provider]
    }

    public func recordPrompt(_ prompt: String, for provider: Provider) {
        lastPrompts[provider] = prompt
    }

    /// The last user turn a mocked model was sent.
    public func lastPrompt(for provider: Provider) -> String? {
        lastPrompts[provider]
    }

    /// A mock model for `provider` that reports each request's user turn back here.
    func model(for provider: Provider, response: MockLanguageModelResponse, clock: any Clock<Duration>) -> MockLanguageModel {
        MockLanguageModel.make(response: response, clock: clock) { [weak self] history in
            await self?.recordPrompt(history.last?.text ?? "", for: provider)
        }
    }

    public func list() -> [String] {
        var keys = byProvider.keys.map(\.rawValue).sorted()
        if globalMock != nil { keys.append("*") }
        return keys
    }
}

extension MockLanguageModelStore.Provider {
    public init?(cloudProviderID: CloudLLMProviderID) {
        switch cloudProviderID {
        case .openAI: self = .openAI
        case .anthropic: self = .anthropic
        case .groq: self = .groq
        case .cerebras: self = .cerebras
        case .custom: self = .custom
        default: return nil
        }
    }
}
