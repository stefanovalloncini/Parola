import Foundation

/// Creates a page under a parent page in Notion for each transcript sent.
public struct NotionDestination: DeliveryDestinationSettings, Codable, Sendable, Equatable {
    public static let kind = DestinationKind.notion
    public static let apiVersion = "2022-06-28"
    static let baseURL = "https://api.notion.com"
    static let maxRateLimitRetries = 3

    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var autoSend: Bool
    public var categories: Set<EntryCategory>
    public var titleFormat: TitleFormat
    public var parentPageID: String
    public var secretRef: String
    public var environment: DeliveryEnvironment = .live

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        autoSend: Bool = false,
        categories: Set<EntryCategory> = Set(EntryCategory.allCases),
        titleFormat: TitleFormat = .title,
        parentPageID: String = "",
        secretRef: String = KeychainSecretStore.newReference(),
        environment: DeliveryEnvironment = .live
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.autoSend = autoSend
        self.categories = categories
        self.titleFormat = titleFormat
        self.parentPageID = parentPageID
        self.secretRef = secretRef
        self.environment = environment
    }

    public var secretRefs: [String] { [secretRef] }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, autoSend, categories, titleFormat, parentPageID, secretRef
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
        parentPageID = try c.decodeIfPresent(String.self, forKey: .parentPageID) ?? ""
        secretRef = try c.decode(String.self, forKey: .secretRef)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(autoSend, forKey: .autoSend)
        try c.encode(categories.map(\.rawValue).sorted(), forKey: .categories)
        try c.encode(titleFormat, forKey: .titleFormat)
        try c.encode(parentPageID, forKey: .parentPageID)
        try c.encode(secretRef, forKey: .secretRef)
    }

    // MARK: - Delivery

    public func deliver(_ payload: DeliveryPayload) async throws -> DeliveryReceipt {
        guard NotionPageID.parse(parentPageID) != nil else {
            throw DeliveryError.invalidSetup(name, "Paste the link of the Notion page to add transcripts under.")
        }
        let blocks = NotionBlocks.blocks(for: payload)
        let first = Array(blocks.prefix(NotionBlocks.maxBlocksPerRequest))
        let title = titleFormat.title(for: payload)
        let created = try await call("POST", "/v1/pages", body: .object([
            "parent": .object(["page_id": .string(parentPageID)]),
            "properties": .object([
                "title": .object(["title": .array(Array(NotionBlocks.richText(title.isEmpty ? "Untitled" : title).prefix(1)))]),
            ]),
            "children": .array(first),
        ]))
        try ensureSuccess(created)
        let page = try? JSONDecoder().decode(CreatedPage.self, from: created.body)
        guard let pageID = page?.id else {
            throw DeliveryError.httpStatus(name, created.status, "Notion's answer had no page in it.")
        }
        var sent = first.count
        var rest = blocks.dropFirst(first.count)
        while !rest.isEmpty {
            let batch = Array(rest.prefix(NotionBlocks.maxBlocksPerRequest))
            do {
                let appended = try await call("PATCH", "/v1/blocks/\(pageID)/children", body: .object(["children": .array(batch)]))
                try ensureSuccess(appended)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw DeliveryError.partialDelivery(
                    name, sent: sent, total: blocks.count, reason: error.localizedDescription
                )
            }
            sent += batch.count
            rest = rest.dropFirst(batch.count)
        }
        return DeliveryReceipt(
            destinationID: id, destinationName: name, deliveredAt: Date(),
            location: page?.url.flatMap(URL.init(string:))
        )
    }

    public func checkConnection() async throws -> ConnectionStatus {
        guard let page = NotionPageID.parse(parentPageID) else {
            throw DeliveryError.invalidSetup(name, "Paste the link of the Notion page to add transcripts under.")
        }
        let result = try await call("GET", "/v1/pages/\(page)", body: nil)
        switch result.status {
        case 200..<300:
            return .connected(try? JSONDecoder().decode(PageTitle.self, from: result.body).text)
        case 401: return .unauthorised
        case 403, 404: return .pageNotShared
        default:
            try ensureSuccess(result)
            return .connected(nil)
        }
    }

    // MARK: - Requests

    private func call(_ method: String, _ path: String, body: DestinationConfig?) async throws -> HTTPResult {
        guard let url = URL(string: Self.baseURL + path) else {
            throw DeliveryError.invalidSetup(name, "The page link isn't valid.")
        }
        let secret = try await environment.secret(secretRef, destination: name)
        var request = URLRequest(url: url, timeoutInterval: URLSessionTransport.timeout)
        request.httpMethod = method
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            request.httpBody = try encoder.encode(body)
        }
        var result = try await environment.perform(request, destination: name)
        for _ in 0..<Self.maxRateLimitRetries where result.status == 429 {
            try await environment.clock.sleep(for: .seconds(Self.retryDelay(result)), tolerance: nil)
            result = try await environment.perform(request, destination: name)
        }
        return result
    }

    static func retryDelay(_ result: HTTPResult) -> Double {
        let seconds = result.headers["retry-after"].flatMap(Double.init) ?? 1
        return min(max(seconds, 1), 60)
    }

    private func ensureSuccess(_ result: HTTPResult) throws {
        guard !result.isSuccess else { return }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: result.body))?.message ?? ""
        throw DeliveryError.httpStatus(name, result.status, String(message.prefix(200)))
    }

    private struct CreatedPage: Decodable {
        var id: String
        var url: String?
    }

    private struct ErrorBody: Decodable {
        var message: String?
    }

    private struct PageTitle: Decodable {
        struct Property: Decodable {
            struct Run: Decodable { var plain_text: String }
            var title: [Run]?
        }
        var properties: [String: Property]?

        var text: String? {
            let joined = properties?["title"]?.title?.map(\.plain_text).joined()
            return joined?.isEmpty == false ? joined : nil
        }
    }
}
