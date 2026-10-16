import Foundation

/// Writes a Markdown note into an open vault through the Obsidian Local REST API plugin.
public struct ObsidianLocalRESTDestination: DeliveryDestinationSettings, Codable, Sendable, Equatable {
    public static let kind = DestinationKind.obsidianREST
    public static let defaultBaseURL = "https://127.0.0.1:27124"

    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var autoSend: Bool
    public var categories: Set<EntryCategory>
    public var titleFormat: TitleFormat
    public var baseURLText: String
    public var secretRef: String
    public var folder: String
    public var filenameTemplate: String
    public var collision: ObsidianCollisionPolicy
    public var frontmatter: ObsidianFrontmatterOptions
    public var body: ObsidianBodyOptions
    public var wikilinks: Bool
    public var environment: DeliveryEnvironment = .live

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        autoSend: Bool = false,
        categories: Set<EntryCategory> = Set(EntryCategory.allCases),
        titleFormat: TitleFormat = .title,
        baseURLText: String = ObsidianLocalRESTDestination.defaultBaseURL,
        secretRef: String = KeychainSecretStore.newReference(),
        folder: String = "",
        filenameTemplate: String = ObsidianVaultFolderDestination.defaultFilenameTemplate,
        collision: ObsidianCollisionPolicy = .appendCounter,
        frontmatter: ObsidianFrontmatterOptions = ObsidianFrontmatterOptions(),
        body: ObsidianBodyOptions = ObsidianBodyOptions(),
        wikilinks: Bool = false,
        environment: DeliveryEnvironment = .live
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.autoSend = autoSend
        self.categories = categories
        self.titleFormat = titleFormat
        self.baseURLText = baseURLText
        self.secretRef = secretRef
        self.folder = folder
        self.filenameTemplate = filenameTemplate
        self.collision = collision
        self.frontmatter = frontmatter
        self.body = body
        self.wikilinks = wikilinks
        self.environment = environment
    }

    public var secretRefs: [String] { [secretRef] }

    public var noteOptions: ObsidianNoteOptions {
        ObsidianNoteOptions(frontmatter: frontmatter, body: body, wikilinks: wikilinks)
    }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, autoSend, categories, titleFormat
        case baseURLText, secretRef, folder, filenameTemplate, collision, frontmatter, body, wikilinks
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
        baseURLText = try c.decodeIfPresent(String.self, forKey: .baseURLText) ?? Self.defaultBaseURL
        secretRef = try c.decode(String.self, forKey: .secretRef)
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        filenameTemplate = try c.decodeIfPresent(String.self, forKey: .filenameTemplate)
            ?? ObsidianVaultFolderDestination.defaultFilenameTemplate
        collision = try c.decodeIfPresent(ObsidianCollisionPolicy.self, forKey: .collision) ?? .appendCounter
        frontmatter = try c.decodeIfPresent(ObsidianFrontmatterOptions.self, forKey: .frontmatter)
            ?? ObsidianFrontmatterOptions()
        body = try c.decodeIfPresent(ObsidianBodyOptions.self, forKey: .body) ?? ObsidianBodyOptions()
        wikilinks = try c.decodeIfPresent(Bool.self, forKey: .wikilinks) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(autoSend, forKey: .autoSend)
        try c.encode(categories.map(\.rawValue).sorted(), forKey: .categories)
        try c.encode(titleFormat, forKey: .titleFormat)
        try c.encode(baseURLText, forKey: .baseURLText)
        try c.encode(secretRef, forKey: .secretRef)
        try c.encode(folder, forKey: .folder)
        try c.encode(filenameTemplate, forKey: .filenameTemplate)
        try c.encode(collision, forKey: .collision)
        try c.encode(frontmatter, forKey: .frontmatter)
        try c.encode(body, forKey: .body)
        try c.encode(wikilinks, forKey: .wikilinks)
    }

    // MARK: - Address

    public static func validateBaseURL(_ text: String) -> Result<URL, WebhookURLError> {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return WebhookURLPolicy.validate(trimmed)
    }

    private func baseURL() throws -> URL {
        switch Self.validateBaseURL(baseURLText) {
        case .success(let url): return url
        case .failure(let error): throw DeliveryError.invalidSetup(name, .address(error))
        }
    }

    private func trust(for base: URL) -> TransportTrust {
        base.scheme?.lowercased() == "https" && LoopbackTrust.isLoopback(host: base.host ?? "")
            ? .loopbackSelfSigned
            : .system
    }

    /// `/vault/<folder>/<file>.md`, every component percent-encoded.
    static func vaultPath(folder: String, filename: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        var parts = ["vault"]
        for raw in folder.split(separator: "/", omittingEmptySubsequences: true) {
            if let component = ObsidianNoteRenderer.sanitisedPathComponent(String(raw)) { parts.append(component) }
        }
        parts.append(filename)
        return "/" + parts.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }.joined(separator: "/")
    }

    // MARK: - Delivery

    public func deliver(_ payload: DeliveryPayload) async throws -> DeliveryReceipt {
        let base = try baseURL()
        let key = try await environment.secret(secretRef, destination: name)
        let stem = ObsidianNoteRenderer.filename(template: filenameTemplate, payload: payload)
        let note = ObsidianNoteRenderer.render(payload, options: noteOptions, title: titleFormat.title(for: payload))
        let filename = try await freeFilename(stem: stem, base: base, key: key)
        var request = try makeRequest("PUT", path: Self.vaultPath(folder: folder, filename: filename), base: base, key: key)
        request.setValue("text/markdown", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(note.utf8)
        let result = try await environment.perform(request, trust: trust(for: base), destination: name)
        guard result.isSuccess else { throw DeliveryError.httpStatus(name, result.status, "") }
        return DeliveryReceipt(destinationID: id, destinationName: name, deliveredAt: Date(), location: nil)
    }

    public func checkConnection() async throws -> ConnectionStatus {
        let base = try baseURL()
        let key = try await environment.secret(secretRef, destination: name)
        let request = try makeRequest("GET", path: "/", base: base, key: key)
        let result = try await environment.perform(request, trust: trust(for: base), destination: name)
        if result.status == 401 || result.status == 403 { return .unauthorised }
        guard result.isSuccess else { throw DeliveryError.httpStatus(name, result.status, "") }
        let status = try? JSONDecoder().decode(ServerStatus.self, from: result.body)
        return status?.authenticated == false ? .unauthorised : .connected(nil)
    }

    private struct ServerStatus: Decodable {
        var authenticated: Bool?
    }

    private func makeRequest(_ method: String, path: String, base: URL, key: String) throws -> URLRequest {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw DeliveryError.invalidSetup(name, .address(.notAURL))
        }
        components.percentEncodedPath = components.percentEncodedPath + path
        guard let url = components.url else {
            throw DeliveryError.invalidSetup(name, .address(.notAURL))
        }
        var request = URLRequest(url: url, timeoutInterval: URLSessionTransport.timeout)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func freeFilename(stem: String, base: URL, key: String) async throws -> String {
        guard collision == .appendCounter else { return stem + ".md" }
        for counter in 1..<100 {
            let candidate = (counter == 1 ? stem : "\(stem) \(counter)") + ".md"
            let probe = try makeRequest("GET", path: Self.vaultPath(folder: folder, filename: candidate), base: base, key: key)
            let result = try await environment.perform(probe, trust: trust(for: base), destination: name)
            if result.status == 404 { return candidate }
            guard result.isSuccess else { throw DeliveryError.httpStatus(name, result.status, "") }
        }
        return "\(stem) \(UUID().uuidString).md"
    }
}
