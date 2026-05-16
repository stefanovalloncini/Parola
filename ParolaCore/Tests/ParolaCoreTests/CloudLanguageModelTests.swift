import Foundation
import Testing
@testable import ParolaCore

@Suite("BYOK cloud language model")
struct CloudLanguageModelTests {
    @Test("OpenAI request has bearer auth, JSON body with role messages, and POSTs to /chat/completions")
    func openAIRequest() async throws {
        let model = CloudLanguageModel(provider: .openAI, model: "gpt-4o-mini", apiKey: "sk-test")
        let (request, _) = try await model.buildRequest(prompt: "Hello there")
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
    func anthropicRequest() async throws {
        let model = CloudLanguageModel(provider: .anthropic, model: "claude-haiku-4-5", apiKey: "sk-ant-test")
        let (request, _) = try await model.buildRequest(prompt: "Summarize this")
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
    func groqRequest() async throws {
        let model = CloudLanguageModel(provider: .groq, model: "llama-3.3-70b-versatile", apiKey: "gsk-test")
        let (request, _) = try await model.buildRequest(prompt: "Hi")
        #expect(request.url?.host == "api.groq.com")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer gsk-test")
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

    @Test("CloudLLMProviderInfo.info returns metadata for known providers and nil for unknown")
    func providerInfoLookup() {
        #expect(CloudLLMProviderInfo.info(for: .openAI)?.displayName == "OpenAI")
        #expect(CloudLLMProviderInfo.info(for: .anthropic)?.displayName == "Anthropic")
        #expect(CloudLLMProviderInfo.info(for: .groq)?.displayName == "Groq")
        #expect(CloudLLMProviderInfo.info(for: CloudLLMProviderID("unknown")) == nil)
    }
}
