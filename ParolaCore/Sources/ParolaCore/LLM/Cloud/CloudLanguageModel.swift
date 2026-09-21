import Foundation

enum CloudStreamLine: Equatable, Sendable {
    case text(String)
    case streamError(String)
    case ignore
}

struct CloudLanguageModel: LanguageModel {
    private static let streamingSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    private let provider: CloudLLMProviderID
    private let model: String
    private let apiKey: String
    private let instructions: String
    private let session: URLSession
    /// Set for a user-supplied OpenAI-compatible server; nil for the providers we ship URLs for.
    private let baseURL: URL?

    init(
        provider: CloudLLMProviderID,
        model: String? = nil,
        apiKey: String,
        instructions: String = LanguageModelFactory.defaultInstructions,
        session: URLSession? = nil
    ) {
        self.provider = provider
        self.model = model ?? CloudLLMProviderInfo.info(for: provider)?.defaultModel ?? ""
        self.apiKey = apiKey
        self.instructions = instructions
        self.session = session ?? Self.streamingSession
        self.baseURL = nil
    }

    init(
        openAICompatibleBaseURL baseURL: URL,
        model: String,
        apiKey: String?,
        instructions: String = LanguageModelFactory.defaultInstructions,
        session: URLSession? = nil
    ) {
        self.provider = .custom
        self.model = model
        self.apiKey = apiKey ?? ""
        self.instructions = instructions
        self.session = session ?? Self.streamingSession
        self.baseURL = baseURL
    }

    static func isSupported(_ provider: CloudLLMProviderID) -> Bool {
        switch provider {
        case .openAI, .anthropic, .groq, .cerebras: return true
        default: return false
        }
    }

    func respond(history: [ChatTurn]) async throws -> String {
        try TokenBudget.check(history: history, system: instructions, provider: provider)
        let (request, decode) = try buildRequest(history: history, streaming: false)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudLLMError.malformedResponse(provider: provider)
        }
        guard (200..<300).contains(http.statusCode) else {
            ParolaLog.error(.ai, "\(provider) request failed with HTTP \(http.statusCode)")
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudLLMError.requestFailed(provider: provider, status: http.statusCode, body: body)
        }
        return try decode(data)
    }

    func stream(history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try TokenBudget.check(history: history, system: instructions, provider: provider)
                    let (request, parseLine) = try buildStreamingRequest(history: history)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw CloudLLMError.malformedResponse(provider: provider)
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            body += line + "\n"
                            if body.utf8.count > 8 * 1024 { break }
                        }
                        throw CloudLLMError.requestFailed(provider: provider, status: http.statusCode, body: body)
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        switch parseLine(line) {
                        case .text(let chunk):
                            if !chunk.isEmpty { continuation.yield(chunk) }
                        case .streamError(let message):
                            throw CloudLLMError.streamError(provider: provider, message: message)
                        case .ignore:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    if !(error is CancellationError) {
                        ParolaLog.error(
                            .ai, "\(provider) stream failed", [.error: .error(error)]
                        )
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func buildRequest(prompt: String) throws -> (URLRequest, (Data) throws -> String) {
        try buildRequest(history: [ChatTurn(role: .user, text: prompt)], streaming: false)
    }

    func buildRequest(
        history: [ChatTurn],
        streaming: Bool
    ) throws -> (URLRequest, (Data) throws -> String) {
        if let baseURL {
            return try buildOpenAICompatibleRequest(
                url: baseURL.appending(path: "chat/completions"),
                history: history,
                streaming: streaming
            )
        }
        switch provider {
        case .openAI:
            return try buildOpenAICompatibleRequest(
                url: URL(string: "https://api.openai.com/v1/chat/completions")!,
                history: history,
                streaming: streaming
            )
        case .groq:
            return try buildOpenAICompatibleRequest(
                url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
                history: history,
                streaming: streaming
            )
        case .cerebras:
            return try buildOpenAICompatibleRequest(
                url: URL(string: "https://api.cerebras.ai/v1/chat/completions")!,
                history: history,
                streaming: streaming
            )
        case .anthropic:
            return try buildAnthropicRequest(history: history, streaming: streaming)
        default:
            throw CloudLLMError.unsupportedProvider(provider)
        }
    }

    func buildStreamingRequest(
        history: [ChatTurn]
    ) throws -> (URLRequest, @Sendable (String) -> CloudStreamLine) {
        let parser: @Sendable (String) -> CloudStreamLine
        if baseURL != nil {
            parser = Self.parseOpenAIStreamLine
        } else {
            switch provider {
            case .openAI, .groq, .cerebras: parser = Self.parseOpenAIStreamLine
            case .anthropic: parser = Self.parseAnthropicStreamLine
            default: throw CloudLLMError.unsupportedProvider(provider)
            }
        }
        let (request, _) = try buildRequest(history: history, streaming: true)
        return (request, parser)
    }

    private func openAIMessages(history: [ChatTurn]) -> [[String: String]] {
        var messages: [[String: String]] = [["role": "system", "content": instructions]]
        for turn in history {
            messages.append(["role": turn.role == .user ? "user" : "assistant", "content": turn.text])
        }
        return messages
    }

    private func anthropicMessages(history: [ChatTurn]) -> [[String: String]] {
        history.map { ["role": $0.role == .user ? "user" : "assistant", "content": $0.text] }
    }

    private func buildOpenAICompatibleRequest(
        url: URL,
        history: [ChatTurn],
        streaming: Bool
    ) throws -> (URLRequest, (Data) throws -> String) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = [
            "model": model,
            "messages": openAIMessages(history: history)
        ]
        if streaming { body["stream"] = true }
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

    private func buildAnthropicRequest(
        history: [ChatTurn],
        streaming: Bool
    ) throws -> (URLRequest, (Data) throws -> String) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": instructions,
            "messages": anthropicMessages(history: history)
        ]
        if streaming { body["stream"] = true }
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

    static func parseOpenAIStreamLine(_ line: String) -> CloudStreamLine {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return .ignore }
        let payload = String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" || payload.isEmpty { return .ignore }
        guard let data = payload.data(using: .utf8) else { return .ignore }
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta
            }
            struct ErrorInfo: Decodable { let message: String? }
            let choices: [Choice]?
            let error: ErrorInfo?
        }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { return .ignore }
        if let error = chunk.error { return .streamError(error.message ?? "stream error") }
        guard let content = chunk.choices?.first?.delta.content else { return .ignore }
        return .text(content)
    }

    static func parseAnthropicStreamLine(_ line: String) -> CloudStreamLine {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return .ignore }
        let payload = String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return .ignore }
        guard let data = payload.data(using: .utf8) else { return .ignore }
        struct Event: Decodable {
            struct Delta: Decodable { let type: String?; let text: String? }
            struct ErrorInfo: Decodable { let message: String? }
            let type: String
            let delta: Delta?
            let error: ErrorInfo?
        }
        guard let event = try? JSONDecoder().decode(Event.self, from: data) else { return .ignore }
        if event.type == "error" {
            return .streamError(event.error?.message ?? "stream error")
        }
        if event.type == "content_block_delta", let text = event.delta?.text {
            return .text(text)
        }
        return .ignore
    }
}
