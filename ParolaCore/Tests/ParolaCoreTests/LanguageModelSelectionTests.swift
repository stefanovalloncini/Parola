import Foundation
import os
import Testing
import Clocks
@testable import ParolaCore
import ParolaTestSupport

@Suite("Language model selection", .serialized)
struct LanguageModelSelectionTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func roundTrip(_ choice: LanguageModelProviderChoice) throws -> LanguageModelProviderChoice {
        try decoder.decode(LanguageModelProviderChoice.self, from: try encoder.encode(choice))
    }

    private func decodeChoice(_ json: String) throws -> LanguageModelProviderChoice {
        try decoder.decode(LanguageModelProviderChoice.self, from: Data(json.utf8))
    }

    private let ollamaEndpoint = URL(string: "http://127.0.0.1:11434")!

    @Test("every choice survives a JSON round trip")
    func choiceRoundTrip() throws {
        let choices: [LanguageModelProviderChoice] = [
            .onDevice,
            .cloud(provider: .openAI, model: "gpt-4o-mini"),
            .ollama(endpoint: ollamaEndpoint, model: "llama3.2:3b"),
            .custom(baseURL: URL(string: "https://llm.example.com/v1")!, model: "local-model"),
        ]
        for choice in choices {
            #expect(try roundTrip(choice) == choice)
        }
    }

    @Test("a choice encodes as a tagged object")
    func choiceEncodesKind() throws {
        let data = try encoder.encode(LanguageModelProviderChoice.cloud(provider: .groq, model: "llama-3.3-70b-versatile"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["kind"] as? String == "cloud")
        #expect(object["provider"] as? String == "groq")
        #expect(object["model"] as? String == "llama-3.3-70b-versatile")
    }

    @Test("a kind written by a newer version decodes as on-device")
    func unknownKindDecodesOnDevice() throws {
        #expect(try decodeChoice(#"{"kind":"quantum","model":"q-1"}"#) == .onDevice)
        #expect(try decodeChoice(#"{"kind":"cloud"}"#) == .onDevice)
        #expect(try decodeChoice(#"{}"#) == .onDevice)
    }

    @Test("an unselected task reads as on-device, and an unknown task key is dropped")
    func selectionDefaults() throws {
        var selection = LanguageModelSelection.onDevice
        #expect(selection[.summary] == .onDevice)
        selection[.summary] = .ollama(endpoint: ollamaEndpoint, model: "llama3.2:3b")
        #expect(selection[.summary] == .ollama(endpoint: ollamaEndpoint, model: "llama3.2:3b"))
        #expect(selection[.chat] == .onDevice)

        let decoded = try decoder.decode(
            LanguageModelSelection.self,
            from: Data(#"{"choices":{"summary":{"kind":"onDevice"},"telepathy":{"kind":"onDevice"}}}"#.utf8)
        )
        #expect(decoded.choices.count == 1)
        #expect(decoded[.summary] == .onDevice)
    }

    @Test("a selection survives a JSON round trip")
    func selectionRoundTrip() throws {
        var selection = LanguageModelSelection.onDevice
        selection[.summary] = .cloud(provider: .anthropic, model: "claude-haiku-4-5")
        selection[.dictationCleanup] = .ollama(endpoint: ollamaEndpoint, model: "llama3.2:3b")
        let decoded = try decoder.decode(LanguageModelSelection.self, from: try encoder.encode(selection))
        #expect(decoded == selection)
    }

    @Test("only cloud, custom and off-box Ollama count as remote")
    func remoteChoices() {
        #expect(LanguageModelProviderChoice.onDevice.isRemote == false)
        #expect(LanguageModelProviderChoice.ollama(endpoint: ollamaEndpoint, model: "m").isRemote == false)
        #expect(LanguageModelProviderChoice.ollama(endpoint: URL(string: "http://localhost:11434")!, model: "m").isRemote == false)
        #expect(LanguageModelProviderChoice.ollama(endpoint: URL(string: "http://[::1]:11434")!, model: "m").isRemote == false)
        #expect(LanguageModelProviderChoice.ollama(endpoint: URL(string: "http://ai.example.com")!, model: "m").isRemote)
        #expect(LanguageModelProviderChoice.cloud(provider: .openAI, model: "gpt-4o-mini").isRemote)
        #expect(LanguageModelProviderChoice.custom(baseURL: URL(string: "http://127.0.0.1:8080/v1")!, model: "m").isRemote)
    }

    // MARK: - Factory routing

    private func selection(_ choice: LanguageModelProviderChoice, for task: LanguageModelTask) -> LanguageModelSelection {
        var selection = LanguageModelSelection.onDevice
        selection[task] = choice
        return selection
    }

    private func answer(
        _ choice: LanguageModelProviderChoice,
        task: LanguageModelTask = .summary,
        keyStore: any APIKeyStore = InMemoryAPIKeyStore(),
        managed: ManagedConfiguration = ManagedConfiguration(storage: temporaryDefaults("parola-selection-"))
    ) async throws -> String {
        let model = try await LanguageModelFactory.make(
            for: task,
            selection: selection(choice, for: task),
            instructions: "be brief",
            keyStore: keyStore,
            managed: managed,
            clock: ImmediateClock()
        )
        return try await model.respond(to: "hello")
    }

    /// Installs the given mocks, runs the body, and clears the process-global store whether the body
    /// returns or throws. A `defer { Task { … } }` would not be ordered against the next test.
    private func withMocks<T>(
        _ responses: [MockLanguageModelStore.Provider: String],
        _ body: () async throws -> T
    ) async throws -> T {
        await MockLanguageModelStore.shared.clear()
        for (provider, text) in responses {
            await MockLanguageModelStore.shared.install(
                provider: provider,
                response: MockLanguageModelResponse(text: text)
            )
        }
        do {
            let value = try await body()
            await MockLanguageModelStore.shared.clear()
            return value
        } catch {
            await MockLanguageModelStore.shared.clear()
            throw error
        }
    }

    @Test("each choice routes to its own provider")
    func routesPerChoice() async throws {
        try await withMocks([
            .foundation: "from apple",
            .openAI: "from openai",
            .ollama: "from ollama",
            .custom: "from custom",
        ]) {
            let onDevice = try await answer(.onDevice)
            let cloud = try await answer(.cloud(provider: .openAI, model: "gpt-4o-mini"))
            let ollama = try await answer(.ollama(endpoint: ollamaEndpoint, model: "llama3.2:3b"))
            let custom = try await answer(.custom(baseURL: URL(string: "https://llm.example.com/v1")!, model: "m"))
            #expect(onDevice == "from apple")
            #expect(cloud == "from openai")
            #expect(ollama == "from ollama")
            #expect(custom == "from custom")
        }
    }

    @Test("the chosen cloud model overrides the provider default")
    func cloudModelOverride() async throws {
        try await withMocks([:]) {
            let keyStore = InMemoryAPIKeyStore(keys: [.openAI: "sk-test"])
            let model = try await LanguageModelFactory.make(
                for: .summary,
                selection: selection(.cloud(provider: .openAI, model: "gpt-4.1-mini"), for: .summary),
                instructions: "be brief",
                keyStore: keyStore,
                managed: ManagedConfiguration(storage: temporaryDefaults("parola-selection-"))
            )
            let cloud = try #require(model as? CloudLanguageModel)
            let (request, _) = try cloud.buildRequest(prompt: "hi")
            let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
            #expect(body?["model"] as? String == "gpt-4.1-mini")
        }
    }

    @Test("a cloud choice without a key fails instead of falling back")
    func cloudWithoutKey() async throws {
        try await withMocks([:]) {
            await #expect(throws: CloudLLMError.self) {
                _ = try await answer(.cloud(provider: .openAI, model: "gpt-4o-mini"))
            }
        }
    }

    // MARK: - Policy

    private func managedWithoutCloud() -> ManagedConfiguration {
        let defaults = temporaryDefaults("parola-selection-policy-")
        defaults.set(["disableCloudLLM": true], forKey: "com.apple.configuration.managed")
        return ManagedConfiguration(storage: defaults)
    }

    /// `CloudLLMError` isn't Equatable, so the case is matched by hand the way the BYOK suite does.
    private func expectDisabledByPolicy(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            Issue.record("expected disabledByPolicy", sourceLocation: sourceLocation)
        } catch let error as CloudLLMError {
            guard case .disabledByPolicy = error else {
                Issue.record("expected disabledByPolicy, got \(error)", sourceLocation: sourceLocation)
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test("policy refuses cloud, custom and off-box Ollama, and still allows loopback Ollama")
    func policyRefusesRemote() async throws {
        let managed = managedWithoutCloud()
        let keyStore = InMemoryAPIKeyStore(keys: [.openAI: "sk-test", .custom: "sk-custom"])

        try await withMocks([:]) {
            await expectDisabledByPolicy {
                _ = try await answer(.cloud(provider: .openAI, model: "gpt-4o-mini"), keyStore: keyStore, managed: managed)
            }
            await expectDisabledByPolicy {
                _ = try await answer(.custom(baseURL: URL(string: "https://llm.example.com/v1")!, model: "m"), keyStore: keyStore, managed: managed)
            }
            await expectDisabledByPolicy {
                _ = try await answer(.ollama(endpoint: URL(string: "http://ai.example.com")!, model: "m"), keyStore: keyStore, managed: managed)
            }
        }

        try await withMocks([.ollama: "from ollama"]) {
            let loopback = try await answer(.ollama(endpoint: ollamaEndpoint, model: "llama3.2:3b"), keyStore: keyStore, managed: managed)
            #expect(loopback == "from ollama")
        }
    }

    // MARK: - Custom endpoint

    @Test("a custom endpoint speaks OpenAI chat completions under the base URL")
    func customEndpointRequest() async throws {
        try await withMocks([:]) {
        let keyStore = InMemoryAPIKeyStore(keys: [.custom: "sk-custom"])
        let model = try await LanguageModelFactory.make(
            for: .prompts,
            selection: selection(.custom(baseURL: URL(string: "http://10.0.0.2:8080/v1/")!, model: "qwen"), for: .prompts),
            instructions: "be brief",
            keyStore: keyStore,
            managed: ManagedConfiguration(storage: temporaryDefaults("parola-selection-"))
        )
        let cloud = try #require(model as? CloudLanguageModel)
        let (request, _) = try cloud.buildRequest(prompt: "hi")
        #expect(request.url?.absoluteString == "http://10.0.0.2:8080/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-custom")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        #expect(body?["model"] as? String == "qwen")
        let messages = body?["messages"] as? [[String: String]]
        #expect(messages?.first?["role"] == "system")
        #expect(messages?.last?["content"] == "hi")
        }
    }

    @Test("a keyless custom endpoint sends no authorization header")
    func customEndpointWithoutKey() async throws {
        try await withMocks([:]) {
        let model = try await LanguageModelFactory.make(
            for: .prompts,
            selection: selection(.custom(baseURL: URL(string: "http://10.0.0.2:8080/v1")!, model: "qwen"), for: .prompts),
            instructions: "be brief",
            keyStore: InMemoryAPIKeyStore(),
            managed: ManagedConfiguration(storage: temporaryDefaults("parola-selection-"))
        )
        let cloud = try #require(model as? CloudLanguageModel)
        let (request, _) = try cloud.buildRequest(prompt: "hi")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }

    @Test("a custom endpoint decodes an OpenAI-shaped reply from a stubbed session")
    func customEndpointDecodesReply() async throws {
        try await withMocks([:]) {
        let payload = #"{"choices":[{"message":{"content":"OK"}}]}"#
        let session = StubURLProtocol.session(status: 200, body: Data(payload.utf8))
        let model = CloudLanguageModel(
            openAICompatibleBaseURL: URL(string: "http://10.0.0.2:8080/v1")!,
            model: "qwen",
            apiKey: nil,
            instructions: "be brief",
            session: session
        )
        let reply = try await model.respond(to: "say ok")
        #expect(reply == "OK")
        #expect(StubURLProtocol.lastURL()?.absoluteString == "http://10.0.0.2:8080/v1/chat/completions")
        }
    }
}

/// Answers every request with one canned response, so a request-shape test never leaves the machine.
final class StubURLProtocol: URLProtocol {
    private struct State: Sendable {
        var status = 200
        var body = Data()
        var lastURL: URL?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func session(status: Int, body: Data) -> URLSession {
        state.withLock {
            $0.status = status
            $0.body = body
            $0.lastURL = nil
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func lastURL() -> URL? { state.withLock { $0.lastURL } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "http://stub.invalid")!
        let canned = Self.state.withLock { state -> (status: Int, body: Data) in
            state.lastURL = url
            return (state.status, state.body)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: canned.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
