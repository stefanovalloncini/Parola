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
        try await deliver(payload, resume: nil)
    }

    public func deliver(_ payload: DeliveryPayload, resume: String?) async throws -> DeliveryReceipt {
        guard let parent = NotionPageID.parse(parentPageID) else {
            throw DeliveryError.invalidSetup(name, .notionPage)
        }
        let blocks = NotionBlocks.blocks(for: payload, headings: environment.notionHeadings)
        let title = titleFormat.title(for: payload)
        let fingerprint = Self.fingerprint(parent: parent, title: title, blocks: blocks)
        var progress: PageProgress
        var resumedFrom: Int?
        if let saved = PageProgress(token: resume), saved.fingerprint == fingerprint, saved.sent <= blocks.count {
            progress = saved
            resumedFrom = saved.sent
        } else {
            progress = try await createPage(parent: parent, title: title, blocks: blocks, fingerprint: fingerprint)
        }
        while progress.sent < blocks.count {
            let batch = Array(blocks[progress.sent...].prefix(NotionBlocks.maxBlocksPerRequest))
            do {
                let appended = try await call("PATCH", "/v1/blocks/\(progress.pageID)/children", body: .object(["children": .array(batch)]))
                try ensureSuccess(appended)
            } catch {
                let cause: DeliveryError
                if error is CancellationError {
                    cause = .networkFailed(Self.host, .cancelled)
                } else {
                    cause = error as? DeliveryError ?? .networkFailed(Self.host, .other)
                }
                if resumedFrom == progress.sent, Self.isPageGone(cause) {
                    resumedFrom = nil
                    progress = try await createPage(parent: parent, title: title, blocks: blocks, fingerprint: fingerprint)
                    continue
                }
                throw DeliveryError.partialDelivery(
                    name, sent: progress.sent, total: blocks.count, underlying: cause, resume: progress.token
                )
            }
            resumedFrom = nil
            progress.sent += batch.count
        }
        return DeliveryReceipt(
            destinationID: id, destinationName: name, deliveredAt: Date(),
            location: progress.url.flatMap(URL.init(string:))
        )
    }

    /// The page a resume points at was trashed or deleted: Notion answers 404, or 400 for an archived block.
    static func isPageGone(_ error: DeliveryError) -> Bool {
        guard case .httpStatus(_, let status, let detail) = error else { return false }
        return status == 404 || (status == 400 && detail.lowercased().contains("archived"))
    }

    private func createPage(parent: String, title: String, blocks: [DestinationConfig], fingerprint: String) async throws -> PageProgress {
        let first = Array(blocks.prefix(NotionBlocks.maxBlocksPerRequest))
        let created = try await call("POST", "/v1/pages", body: .object([
            "parent": .object(["page_id": .string(parent)]),
            "properties": .object([
                "title": .object(["title": .array(Array(NotionBlocks.richText(title.isEmpty ? "Untitled" : title).prefix(1)))]),
            ]),
            "children": .array(first),
        ]))
        try ensureSuccess(created)
        guard let page = try? JSONDecoder().decode(CreatedPage.self, from: created.body) else {
            throw DeliveryError.pageNotReturned(name)
        }
        return PageProgress(pageID: page.id, url: page.url, sent: first.count, fingerprint: fingerprint)
    }

    static let host = "api.notion.com"

    /// Stable across launches, so a retry after a restart can tell the transcript has not changed.
    static func fingerprint(parent: String, title: String, blocks: [DestinationConfig]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(blocks)) ?? Data()
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in Data(parent.utf8) + Data(title.utf8) + data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    struct PageProgress: Equatable {
        var pageID: String
        var url: String?
        var sent: Int
        var fingerprint: String

        init(pageID: String, url: String?, sent: Int, fingerprint: String) {
            self.pageID = pageID
            self.url = url
            self.sent = sent
            self.fingerprint = fingerprint
        }

        init?(token: String?) {
            guard let token else { return nil }
            let parts = token.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, let sent = Int(parts[1]) else { return nil }
            self.init(pageID: parts[0], url: parts[3].isEmpty ? nil : parts[3], sent: sent, fingerprint: parts[2])
        }

        var token: String { "\(pageID)|\(sent)|\(fingerprint)|\(url ?? "")" }
    }

    public func checkConnection() async throws -> ConnectionStatus {
        guard let page = NotionPageID.parse(parentPageID) else {
            throw DeliveryError.invalidSetup(name, .notionPage)
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
            throw DeliveryError.invalidSetup(name, .notionPage)
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

    /// Seconds to wait: `Retry-After` as a number of seconds or as an HTTP date, kept between 1 and 60.
    static func retryDelay(_ result: HTTPResult, now: Date = Date()) -> Double {
        let seconds: Double
        if let header = result.headers["retry-after"]?.trimmingCharacters(in: .whitespaces) {
            if let number = Double(header), number.isFinite {
                seconds = number
            } else if let date = Self.httpDate(header) {
                seconds = date.timeIntervalSince(now)
            } else {
                seconds = 1
            }
        } else {
            seconds = 1
        }
        return min(max(seconds, 1), 60)
    }

    private static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    private func ensureSuccess(_ result: HTTPResult) throws {
        guard !result.isSuccess else { return }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: result.body))?.message ?? ""
        throw DeliveryError.http(name, result.status, detail: String(message.prefix(200)))
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
