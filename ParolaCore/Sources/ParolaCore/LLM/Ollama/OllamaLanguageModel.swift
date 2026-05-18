import Foundation

public struct OllamaLanguageModel: LanguageModel {
    public static let defaultEndpoint = URL(string: "http://localhost:11434")!
    public static let defaultModel = "llama3"

    private let model: String
    private let endpoint: URL
    private let instructions: String
    private let session: URLSession

    public init(
        model: String = OllamaLanguageModel.defaultModel,
        endpoint: URL = OllamaLanguageModel.defaultEndpoint,
        instructions: String = "You're a helpful assistant.",
        session: URLSession = .shared
    ) {
        self.model = model
        self.endpoint = endpoint
        self.instructions = instructions
        self.session = session
    }

    public func respond(history: [ChatTurn]) async throws -> String {
        let (request, decode) = try buildRequest(history: history, streaming: false)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.requestFailed(status: http.statusCode, body: body)
        }
        return try decode(data)
    }

    public func stream(history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (request, _) = try buildRequest(history: history, streaming: true)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw OllamaError.malformedResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines { body += line + "\n" }
                        throw OllamaError.requestFailed(status: http.statusCode, body: body)
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let chunk = Self.parseStreamLine(line), !chunk.isEmpty {
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func buildRequest(prompt: String, streaming: Bool) throws -> (URLRequest, (Data) throws -> String) {
        try buildRequest(history: [ChatTurn(role: .user, text: prompt)], streaming: streaming)
    }

    func buildRequest(
        history: [ChatTurn],
        streaming: Bool
    ) throws -> (URLRequest, (Data) throws -> String) {
        var url = endpoint
        url.append(path: "api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var messages: [[String: String]] = [["role": "system", "content": instructions]]
        for turn in history {
            messages.append(["role": turn.role == .user ? "user" : "assistant", "content": turn.text])
        }
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": streaming,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return (request, { data in
            struct Response: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return decoded.message.content
        })
    }

    static func parseStreamLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        struct Chunk: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
            let done: Bool?
        }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { return nil }
        if chunk.done == true { return nil }
        return chunk.message?.content
    }
}

public enum OllamaError: Error, LocalizedError, Sendable {
    case malformedResponse
    case requestFailed(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .malformedResponse:
            return "Ollama responded with an unexpected payload."
        case .requestFailed(let status, _):
            return "Ollama request failed with HTTP \(status). Make sure Ollama is running locally."
        }
    }
}
