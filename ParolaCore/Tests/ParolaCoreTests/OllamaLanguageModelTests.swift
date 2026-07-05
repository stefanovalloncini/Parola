import Foundation
import Testing
@testable import ParolaCore

@Suite("Ollama language model")
struct OllamaLanguageModelTests {
    @Test("request POSTs to /api/chat on the configured endpoint")
    func endpoint() throws {
        let model = OllamaLanguageModel(model: "llama3", endpoint: URL(string: "http://localhost:11434")!)
        let (request, _) = try model.buildRequest(prompt: "Hello", streaming: false)
        #expect(request.url?.absoluteString == "http://localhost:11434/api/chat")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("request body has model, messages, stream=false, and the system instruction")
    func bodyShape() throws {
        let model = OllamaLanguageModel(model: "llama3", instructions: "act sharp")
        let (request, _) = try model.buildRequest(prompt: "Hi there", streaming: false)
        let json = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        #expect(json?["model"] as? String == "llama3")
        #expect(json?["stream"] as? Bool == false)
        let messages = json?["messages"] as? [[String: String]]
        #expect(messages?.count == 2)
        #expect(messages?.first?["role"] == "system")
        #expect(messages?.first?["content"] == "act sharp")
        #expect(messages?.last?["role"] == "user")
        #expect(messages?.last?["content"] == "Hi there")
    }

    @Test("request body carries options.num_ctx defaulting to 8192")
    func numCtxDefault() throws {
        let model = OllamaLanguageModel(model: "llama3")
        let (request, _) = try model.buildRequest(prompt: "Hi", streaming: false)
        let json = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let options = json?["options"] as? [String: Any]
        #expect(options?["num_ctx"] as? Int == 8192)
    }

    @Test("contextTokens init parameter overrides num_ctx")
    func numCtxOverride() throws {
        let model = OllamaLanguageModel(model: "llama3", contextTokens: 16384)
        let (request, _) = try model.buildRequest(prompt: "Hi", streaming: true)
        let json = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let options = json?["options"] as? [String: Any]
        #expect(options?["num_ctx"] as? Int == 16384)
    }

    @Test("streaming request sets stream=true")
    func streamingFlag() throws {
        let model = OllamaLanguageModel(model: "llama3")
        let (request, _) = try model.buildRequest(prompt: "Hi", streaming: true)
        let json = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        #expect(json?["stream"] as? Bool == true)
    }

    @Test("multi-turn history maps to alternating user/assistant messages")
    func multiTurn() throws {
        let model = OllamaLanguageModel(model: "llama3")
        let history = [
            ChatTurn(role: .user, text: "Q1"),
            ChatTurn(role: .assistant, text: "A1"),
            ChatTurn(role: .user, text: "Q2"),
        ]
        let (request, _) = try model.buildRequest(history: history, streaming: false)
        let json = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let messages = json?["messages"] as? [[String: String]]
        #expect(messages?.count == 4)
        #expect(messages?[0]["role"] == "system")
        #expect(messages?[1]["role"] == "user")
        #expect(messages?[2]["role"] == "assistant")
        #expect(messages?[3]["role"] == "user")
    }

    @Test("decode extracts message.content from JSON envelope")
    func decode() throws {
        let payload = "{\"message\": {\"role\": \"assistant\", \"content\": \"hello world\"}, \"done\": true}"
        let model = OllamaLanguageModel(model: "llama3")
        let (_, decode) = try model.buildRequest(prompt: "x", streaming: false)
        let text = try decode(payload.data(using: .utf8)!)
        #expect(text == "hello world")
    }

    @Test("stream line parser extracts the chunked content delta")
    func streamLine() {
        let line = "{\"message\": {\"role\": \"assistant\", \"content\": \"frag\"}, \"done\": false}"
        #expect(OllamaLanguageModel.parseStreamLine(line) == .text("frag"))
    }

    @Test("stream line parser ignores done envelopes and blanks")
    func streamLineSkips() {
        #expect(OllamaLanguageModel.parseStreamLine("") == .ignore)
        let done = "{\"done\": true, \"total_duration\": 100}"
        #expect(OllamaLanguageModel.parseStreamLine(done) == .ignore)
    }

    @Test("stream line parser surfaces a mid-stream error frame")
    func streamLineError() {
        let line = "{\"error\": \"model runner has unexpectedly stopped\"}"
        #expect(OllamaLanguageModel.parseStreamLine(line) == .streamError("model runner has unexpectedly stopped"))
    }

    @Test("custom endpoint without trailing slash is honored")
    func customEndpoint() throws {
        let model = OllamaLanguageModel(model: "llama3", endpoint: URL(string: "http://10.0.0.5:11434")!)
        let (request, _) = try model.buildRequest(prompt: "Hi", streaming: false)
        #expect(request.url?.absoluteString == "http://10.0.0.5:11434/api/chat")
    }
}
