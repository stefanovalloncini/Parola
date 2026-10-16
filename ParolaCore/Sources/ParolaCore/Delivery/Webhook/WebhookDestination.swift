import Foundation

/// A header on a webhook request. The value is a secret, so only a reference to it is stored.
public struct WebhookHeader: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var secretRef: String

    public init(id: UUID = UUID(), name: String, secretRef: String = KeychainSecretStore.newReference()) {
        self.id = id
        self.name = name
        self.secretRef = secretRef
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        secretRef = try c.decode(String.self, forKey: .secretRef)
    }
}

public enum WebhookURLError: Error, Equatable {
    case empty
    case notAURL
    case unsupportedScheme
    case insecurePublicHost

    public var message: String {
        switch self {
        case .empty: return "Enter the webhook address."
        case .notAURL: return "That isn't a web address."
        case .unsupportedScheme: return "The address has to start with https:// or http://."
        case .insecurePublicHost: return "An address on the internet has to start with https://. Plain http:// is only for this Mac and your local network."
        }
    }
}

public enum WebhookURLPolicy {
    public static func validate(_ text: String) -> Result<URL, WebhookURLError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else { return .failure(.notAURL) }
        switch url.scheme?.lowercased() {
        case "https": return .success(url)
        case "http":
            return NetworkHostPolicy.isLocalOrPrivate(host: host) ? .success(url) : .failure(.insecurePublicHost)
        default: return .failure(.unsupportedScheme)
        }
    }

    public static func isUnencrypted(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http"
    }
}

/// Posts a transcript as JSON to a URL, such as a Zapier, Make or n8n catch hook.
public struct WebhookDestination: DeliveryDestinationSettings, Codable, Sendable, Equatable {
    public static let kind = DestinationKind.webhook

    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var autoSend: Bool
    public var categories: Set<EntryCategory>
    public var titleFormat: TitleFormat
    public var urlText: String
    public var headers: [WebhookHeader]
    public var includeSegments: Bool
    public var environment: DeliveryEnvironment = .live

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        autoSend: Bool = false,
        categories: Set<EntryCategory> = Set(EntryCategory.allCases),
        titleFormat: TitleFormat = .title,
        urlText: String = "",
        headers: [WebhookHeader] = [],
        includeSegments: Bool = true,
        environment: DeliveryEnvironment = .live
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.autoSend = autoSend
        self.categories = categories
        self.titleFormat = titleFormat
        self.urlText = urlText
        self.headers = headers
        self.includeSegments = includeSegments
        self.environment = environment
    }

    public var secretRefs: [String] { headers.map(\.secretRef) }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, autoSend, categories, titleFormat, urlText, headers, includeSegments
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        autoSend = try c.decodeIfPresent(Bool.self, forKey: .autoSend) ?? false
        let rawCategories = try c.decodeIfPresent([String].self, forKey: .categories)
        categories = rawCategories.map { Set($0.compactMap(EntryCategory.init(rawValue:))) }
            ?? Set(EntryCategory.allCases)
        titleFormat = try c.decodeIfPresent(TitleFormat.self, forKey: .titleFormat) ?? .title
        urlText = try c.decodeIfPresent(String.self, forKey: .urlText) ?? ""
        headers = try c.decodeIfPresent([WebhookHeader].self, forKey: .headers) ?? []
        includeSegments = try c.decodeIfPresent(Bool.self, forKey: .includeSegments) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(autoSend, forKey: .autoSend)
        try c.encode(categories.map(\.rawValue).sorted(), forKey: .categories)
        try c.encode(titleFormat, forKey: .titleFormat)
        try c.encode(urlText, forKey: .urlText)
        try c.encode(headers, forKey: .headers)
        try c.encode(includeSegments, forKey: .includeSegments)
    }

    // MARK: - Delivery

    public func deliver(_ payload: DeliveryPayload) async throws -> DeliveryReceipt {
        let result = try await post(payload)
        guard result.isSuccess else {
            throw DeliveryError.http(name, result.status)
        }
        return DeliveryReceipt(destinationID: id, destinationName: name, deliveredAt: Date(), location: nil)
    }

    /// Posts a sample and returns whatever status the server answered, so the editor can show it.
    public func sendTest(_ payload: DeliveryPayload) async throws -> Int {
        try await post(payload).status
    }

    func post(_ payload: DeliveryPayload) async throws -> HTTPResult {
        let url: URL
        switch WebhookURLPolicy.validate(urlText) {
        case .success(let valid): url = valid
        case .failure(let error): throw DeliveryError.invalidSetup(name, .address(error))
        }
        var request = URLRequest(url: url, timeoutInterval: URLSessionTransport.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Parola", forHTTPHeaderField: "User-Agent")
        for header in headers {
            let headerName = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !headerName.isEmpty else { continue }
            let value = try await environment.secret(header.secretRef, destination: name)
            request.setValue(value, forHTTPHeaderField: headerName)
        }
        request.httpBody = try WebhookBody(payload, includeSegments: includeSegments).encoded()
        return try await environment.perform(request, destination: name)
    }
}

/// The JSON a webhook receives. `parola` is the schema version; a field is added, never changed,
/// within a version. See docs/webhooks.md.
public struct WebhookBody: Encodable, Sendable, Equatable {
    public static let version = 1

    struct Chapter: Encodable, Equatable {
        var title: String
        var start: Double
    }

    struct Segment: Encodable, Equatable {
        var start: Double
        var end: Double
        var speaker: String?
        var text: String
    }

    var parola = WebhookBody.version
    var id: String
    var title: String
    var aiTitle: String?
    var createdAt: String
    var duration: Double?
    var language: String
    var category: String
    var sourceApp: String?
    var text: String
    var summary: String?
    var chapters: [Chapter]
    var actionItems: [String]
    var segments: [Segment]?

    init(_ payload: DeliveryPayload, includeSegments: Bool) {
        id = payload.entryID
        title = payload.title
        aiTitle = payload.aiTitle
        createdAt = payload.createdAt.formatted(.iso8601)
        duration = payload.duration
        language = payload.language
        category = payload.category.rawValue
        sourceApp = payload.sourceAppBundleID
        text = payload.transcript.text
        summary = payload.summary?.text
        chapters = (payload.summary?.chapters ?? []).map { Chapter(title: $0.title, start: $0.start) }
        actionItems = payload.summary?.actionItems ?? []
        segments = includeSegments
            ? payload.transcript.segments.map { Segment(start: $0.start, end: $0.end, speaker: $0.speaker, text: $0.text) }
            : nil
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
