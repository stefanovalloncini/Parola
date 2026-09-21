import Foundation

/// The models an Ollama server has pulled, so a picker can offer them instead of asking the user
/// to type a name that has to match exactly.
public enum OllamaCatalog {
    private static let listingSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config)
    }()

    public static func installedModels(
        endpoint: URL,
        session: URLSession? = nil
    ) async throws -> [String] {
        var url = endpoint
        url.append(path: "api/tags")
        let (data, response) = try await (session ?? listingSession).data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OllamaError.requestFailed(status: http.statusCode, body: "")
        }
        struct Listing: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else {
            throw OllamaError.malformedResponse
        }
        return listing.models.map(\.name).sorted()
    }
}
