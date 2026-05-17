import Foundation
import Testing
@testable import ParolaCore

@Suite("BYOK cloud language model")
struct CloudLanguageModelTests {
    @Test("OpenAI request has bearer auth, JSON body with role messages, and POSTs to /chat/completions")
    func openAIRequest() throws {
        let model = CloudLanguageModel(provider: .openAI, model: "gpt-4o-mini", apiKey: "sk-test")
        let (request, _) = try model.buildRequest(prompt: "Hello there")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        #expect(body?["model"] as? String == "gpt-4o-mini")
        let messages = body?["messages"] as? [[String: String]]
        #expect(messages?.count == 2)
        #expect(messages?.first?["role"] == "system")
        #expect(messages?.last?["role"] == "user")
        #expect(messages?.last?["content"] == "Hello there")
    }

    @Test("Anthropic request uses x-api-key, anthropic-version header, system field, /v1/messages")
    func anthropicRequest() throws {
        let model = CloudLanguageModel(provider: .anthropic, model: "claude-haiku-4-5", apiKey: "sk-ant-test")
        let (request, _) = try model.buildRequest(prompt: "Summarize this")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        #expect(body?["model"] as? String == "claude-haiku-4-5")
        #expect(body?["system"] is String)
        let messages = body?["messages"] as? [[String: String]]
        #expect(messages?.count == 1)
        #expect(messages?.first?["role"] == "user")
    }

    @Test("Groq points to api.groq.com OpenAI-compatible endpoint")
    func groqRequest() throws {
        let model = CloudLanguageModel(provider: .groq, model: "llama-3.3-70b-versatile", apiKey: "gsk-test")
        let (request, _) = try model.buildRequest(prompt: "Hi")
        #expect(request.url?.host == "api.groq.com")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer gsk-test")
    }

    @Test("Multi-turn history populates OpenAI messages array in order")
    func openAIMultiTurnHistory() throws {
        let model = CloudLanguageModel(provider: .openAI, apiKey: "sk-test")
        let history = [
            ChatTurn(role: .user, text: "Q1"),
            ChatTurn(role: .assistant, text: "A1"),
            ChatTurn(role: .user, text: "Q2"),
        ]
        let (request, _) = try model.buildRequest(history: history, streaming: false)
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let messages = body?["messages"] as? [[String: String]]
        #expect(messages?.count == 4)
        #expect(messages?[0]["role"] == "system")
        #expect(messages?[1]["role"] == "user")
        #expect(messages?[1]["content"] == "Q1")
        #expect(messages?[2]["role"] == "assistant")
        #expect(messages?[2]["content"] == "A1")
        #expect(messages?[3]["role"] == "user")
        #expect(messages?[3]["content"] == "Q2")
    }

    @Test("Anthropic history skips system role and keeps user/assistant order")
    func anthropicMultiTurnHistory() throws {
        let model = CloudLanguageModel(provider: .anthropic, apiKey: "sk-ant-test")
        let history = [
            ChatTurn(role: .user, text: "Q1"),
            ChatTurn(role: .assistant, text: "A1"),
            ChatTurn(role: .user, text: "Q2"),
        ]
        let (request, _) = try model.buildRequest(history: history, streaming: false)
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let messages = body?["messages"] as? [[String: String]]
        #expect(messages?.count == 3)
        #expect(messages?[0]["role"] == "user")
        #expect(messages?[1]["role"] == "assistant")
        #expect(messages?[2]["role"] == "user")
    }

    @Test("Streaming sets stream:true in OpenAI body")
    func openAIStreaming() throws {
        let model = CloudLanguageModel(provider: .openAI, apiKey: "sk-test")
        let (request, _) = try model.buildRequest(
            history: [ChatTurn(role: .user, text: "Hi")],
            streaming: true
        )
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        #expect(body?["stream"] as? Bool == true)
    }

    @Test("OpenAI stream line parser extracts delta content")
    func openAIStreamParser() {
        let line = #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#
        #expect(CloudLanguageModel.parseOpenAIStreamLine(line) == "Hello")
        #expect(CloudLanguageModel.parseOpenAIStreamLine("data: [DONE]") == nil)
        #expect(CloudLanguageModel.parseOpenAIStreamLine("") == nil)
    }

    @Test("Anthropic stream line parser extracts content_block_delta text")
    func anthropicStreamParser() {
        let line = #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}"#
        #expect(CloudLanguageModel.parseAnthropicStreamLine(line) == "Hi")
        let ping = #"data: {"type":"ping"}"#
        #expect(CloudLanguageModel.parseAnthropicStreamLine(ping) == nil)
    }

    @Test("APIKeyStore (in-memory) round-trips and clears values")
    func apiKeyStoreRoundTrip() async throws {
        let store = InMemoryAPIKeyStore()
        try await store.set("sk-test", for: .openAI)
        #expect(try await store.get(for: .openAI) == "sk-test")
        try await store.set(nil, for: .openAI)
        #expect(try await store.get(for: .openAI) == nil)
    }

    @Test("Factory throws missingAPIKey when no key configured")
    func factoryMissingKey() async {
        let store = InMemoryAPIKeyStore()
        let managed = ManagedConfiguration(storage: UserDefaults(suiteName: "parola-cloud-test-\(UUID().uuidString)")!)
        var thrown: CloudLLMError?
        do {
            _ = try await LanguageModelFactory.makeBYOKCloud(provider: .openAI, keyStore: store, managed: managed)
        } catch let e as CloudLLMError {
            thrown = e
        } catch {}
        switch thrown {
        case .missingAPIKey: break
        default: Issue.record("expected missingAPIKey, got \(String(describing: thrown))")
        }
    }

    @Test("Factory throws disabledByPolicy when MDM disables cloud LLM")
    func factoryDisabledByPolicy() async throws {
        let store = InMemoryAPIKeyStore()
        try await store.set("sk-test", for: .openAI)
        let storage = UserDefaults(suiteName: "parola-cloud-test-\(UUID().uuidString)")!
        storage.set(["disableCloudLLM": true], forKey: "com.apple.configuration.managed")
        let managed = ManagedConfiguration(storage: storage)

        var thrown: CloudLLMError?
        do {
            _ = try await LanguageModelFactory.makeBYOKCloud(provider: .openAI, keyStore: store, managed: managed)
        } catch let e as CloudLLMError {
            thrown = e
        } catch {}
        switch thrown {
        case .disabledByPolicy: break
        default: Issue.record("expected disabledByPolicy, got \(String(describing: thrown))")
        }
    }

    @Test("Factory throws unsupportedProvider for unknown raw value")
    func factoryUnsupportedProvider() async throws {
        let store = InMemoryAPIKeyStore()
        try await store.set("k", for: CloudLLMProviderID("vapor-cloud"))
        let managed = ManagedConfiguration(storage: UserDefaults(suiteName: "parola-cloud-test-\(UUID().uuidString)")!)
        var thrown: CloudLLMError?
        do {
            _ = try await LanguageModelFactory.makeBYOKCloud(
                provider: CloudLLMProviderID("vapor-cloud"),
                keyStore: store,
                managed: managed
            )
        } catch let e as CloudLLMError {
            thrown = e
        } catch {}
        switch thrown {
        case .unsupportedProvider: break
        default: Issue.record("expected unsupportedProvider, got \(String(describing: thrown))")
        }
    }

    @Test("requestFailed errorDescription omits body, debugDescription includes it")
    func requestFailedErrorDescription() {
        let error = CloudLLMError.requestFailed(provider: .openAI, status: 401, body: "secret-key-leak")
        let description = error.errorDescription ?? ""
        #expect(!description.contains("secret-key-leak"))
        #expect(description.contains("401"))
        #expect(error.debugDescription.contains("secret-key-leak"))
    }

    @Test("missingAPIKey error string does not point at a Settings UI menu")
    func missingAPIKeyErrorIsUIFree() {
        let error = CloudLLMError.missingAPIKey(.openAI)
        let description = error.errorDescription ?? ""
        #expect(!description.contains("Settings"))
    }

    @Test("CloudLLMProviderInfo.info returns metadata for known providers and nil for unknown")
    func providerInfoLookup() {
        #expect(CloudLLMProviderInfo.info(for: .openAI)?.displayName == "OpenAI")
        #expect(CloudLLMProviderInfo.info(for: .anthropic)?.displayName == "Anthropic")
        #expect(CloudLLMProviderInfo.info(for: .groq)?.displayName == "Groq")
        #expect(CloudLLMProviderInfo.info(for: CloudLLMProviderID("unknown")) == nil)
    }
}
