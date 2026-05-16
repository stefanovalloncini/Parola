import Foundation

/// Concrete `LanguageModel` adapter that proxies completions to a cloud provider via HTTPS.
/// Constructs the right request body per provider (OpenAI / Anthropic / Groq) and decodes the response.
public struct CloudLanguageModel: LanguageModel {
    private let provider: CloudLLMProviderID
    private let model: String
    private let apiKey: String
    private let instructions: String
    private let session: URLSession

    public init(
        provider: CloudLLMProviderID,
        model: String? = nil,
        apiKey: String,
        instructions: String = "You're a helpful assistant.",
        session: URLSession = .shared
    ) {
        self.provider = provider
        self.model = model ?? CloudLLMProviderInfo.info(for: provider)?.defaultModel ?? ""
        self.apiKey = apiKey
        self.instructions = instructions
        self.session = session
    }

    public func respond(to prompt: String) async throws -> String {
        let (request, decode) = try buildRequest(prompt: prompt)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudLLMError.malformedResponse(provider: provider)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudLLMError.requestFailed(provider: provider, status: http.statusCode, body: body)
        }
        return try decode(data)
    }

    func buildRequest(prompt: String) throws -> (URLRequest, (Data) throws -> String) {
        switch provider {
        case .openAI:
            return try buildOpenAIRequest(prompt: prompt)
        case .anthropic:
            return try buildAnthropicRequest(prompt: prompt)
        case .groq:
            return try buildGroqRequest(prompt: prompt)
        default:
            throw CloudLLMError.malformedResponse(provider: provider)
        }
    }

    private func buildOpenAIRequest(prompt: String) throws -> (URLRequest, (Data) throws -> String) {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let provider = self.provider
        return (request, { data in
            struct Response: Decodable {
                struct Choice: Decodable { let message: Message }
                struct Message: Decodable { let content: String }
                let choices: [Choice]
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let text = decoded.choices.first?.message.content else {
                throw CloudLLMError.malformedResponse(provider: provider)
            }
            return text
        })
    }

    private func buildAnthropicRequest(prompt: String) throws -> (URLRequest, (Data) throws -> String) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": instructions,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let provider = self.provider
        return (request, { data in
            struct Response: Decodable {
                struct Block: Decodable { let type: String; let text: String? }
                let content: [Block]
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let text = decoded.content.compactMap { $0.text }.joined()
            guard !text.isEmpty else {
                throw CloudLLMError.malformedResponse(provider: provider)
            }
            return text
        })
    }

    private func buildGroqRequest(prompt: String) throws -> (URLRequest, (Data) throws -> String) {
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let provider = self.provider
        return (request, { data in
            struct Response: Decodable {
                struct Choice: Decodable { let message: Message }
                struct Message: Decodable { let content: String }
                let choices: [Choice]
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let text = decoded.choices.first?.message.content else {
                throw CloudLLMError.malformedResponse(provider: provider)
            }
            return text
        })
    }
}
