import Foundation

/// The outbound integrations Parola knows the names of. A kind this build does not know still
/// decodes, as ``AnyDestination/unsupported(kind:config:)``.
public enum DestinationKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case obsidianFolder
    case obsidianREST
    case webhook
    case notion

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .obsidianFolder: return "Obsidian vault folder"
        case .obsidianREST: return "Obsidian Local REST"
        case .webhook: return "Webhook"
        case .notion: return "Notion"
        }
    }

    public var isImplemented: Bool { true }
}

/// How a destination names the note it writes.
public enum TitleFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case title
    case aiTitle
    case dateAndTitle

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .title: return "Title"
        case .aiTitle: return "AI title"
        case .dateAndTitle: return "Date and title"
        }
    }

    /// The title for this payload. `aiTitle` falls back to the entry's own title when the
    /// on-device pass never ran.
    public func title(for payload: DeliveryPayload, timeZone: TimeZone = .current) -> String {
        let plain = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .title:
            return plain
        case .aiTitle:
            let ai = payload.aiTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ai.isEmpty ? plain : ai
        case .dateAndTitle:
            return "\(DeliveryDateFormat.day(payload.createdAt, timeZone: timeZone)) \(plain)"
        }
    }
}

/// The date pieces a filename template and a title format write.
public enum DeliveryDateFormat {
    public static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        format(date, pattern: "yyyy-MM-dd", timeZone: timeZone)
    }

    public static func time(_ date: Date, timeZone: TimeZone = .current) -> String {
        format(date, pattern: "HH-mm", timeZone: timeZone)
    }

    private static func format(_ date: Date, pattern: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

/// One place a finished transcript can be sent.
public protocol DeliveryDestination: Sendable, Identifiable {
    static var kind: DestinationKind { get }
    var id: UUID { get }
    var name: String { get }
    var isEnabled: Bool { get }
    var autoSend: Bool { get }
    var categories: Set<EntryCategory> { get }
    var titleFormat: TitleFormat { get }
    /// Throws when the destination can't be written to right now, such as a vault on a drive that isn't
    /// mounted. Cheap: the engine asks before it reads a transcript for a retry.
    func checkReachable() async throws
    func deliver(_ payload: DeliveryPayload) async throws -> DeliveryReceipt
    /// `resume` is whatever the destination's last failed attempt asked to be handed back.
    func deliver(_ payload: DeliveryPayload, resume: String?) async throws -> DeliveryReceipt
}

public extension DeliveryDestination {
    var kind: DestinationKind { Self.kind }

    func checkReachable() async throws {}

    func deliver(_ payload: DeliveryPayload, resume: String?) async throws -> DeliveryReceipt {
        try await deliver(payload)
    }

    func accepts(_ category: EntryCategory) -> Bool {
        categories.contains(category)
    }
}

/// The settings the Send To row edits on any destination.
public protocol DeliveryDestinationSettings: DeliveryDestination {
    var isEnabled: Bool { get set }
    var autoSend: Bool { get set }
    var categories: Set<EntryCategory> { get set }
    var titleFormat: TitleFormat { get set }
}

extension ObsidianVaultFolderDestination: DeliveryDestinationSettings {}
extension MockDestination: DeliveryDestinationSettings {}

/// Why a connection to a server failed, without the system's wording, so the app can say it in its own language.
public enum NetworkFailure: String, Sendable, Equatable {
    case offline, timedOut, cannotConnect, hostNotFound, tlsFailed, cancelled, other

    public init(_ error: any Error) {
        switch (error as? URLError)?.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: self = .offline
        case .timedOut: self = .timedOut
        case .cannotConnectToHost, .networkConnectionLost: self = .cannotConnect
        case .cannotFindHost, .dnsLookupFailed: self = .hostNotFound
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            self = .tlsFailed
        case .cancelled: self = .cancelled
        default: self = .other
        }
    }

    public var message: String {
        switch self {
        case .offline: return "There is no internet connection."
        case .timedOut: return "The server took too long to answer."
        case .cannotConnect: return "The server refused the connection."
        case .hostNotFound: return "The address couldn't be found."
        case .tlsFailed: return "The server's certificate isn't trusted."
        case .cancelled: return "The send was cancelled."
        case .other: return "The connection failed."
        }
    }
}

/// What is wrong with a destination's settings.
public enum SetupProblem: Sendable, Equatable {
    case address(WebhookURLError)
    case notionPage

    public var message: String {
        switch self {
        case .address(let error): return error.message
        case .notionPage: return "Paste the link of the Notion page to add transcripts under."
        }
    }
}

/// Why a delivery could not be made.
public enum DeliveryError: Error, LocalizedError, Equatable {
    case vaultUnavailable(String, String)
    case writeFailed(String, String)
    case httpStatus(String, Int, String)
    case networkFailed(String, NetworkFailure)
    case missingSecret(String)
    case invalidSetup(String, SetupProblem)
    /// The server pointed somewhere else, and Parola does not follow a redirect to another origin.
    case redirected(String, status: Int)
    /// Notion took the page but its answer did not say which one, so a retry could make a second.
    case pageNotReturned(String)
    /// Some of a page went out and the rest did not. `resume` lets the next attempt carry on from there.
    indirect case partialDelivery(String, sent: Int, total: Int, underlying: DeliveryError, resume: String)

    /// The error for a response that is not a success: a refused redirect or a status.
    static func http(_ name: String, _ status: Int, detail: String = "") -> DeliveryError {
        (300..<400).contains(status) ? .redirected(name, status: status) : .httpStatus(name, status, detail)
    }

    /// A failure that sending again cannot fix: the server refused the request, or the settings are wrong.
    public var isPermanent: Bool {
        switch self {
        case .httpStatus(_, let status, _): return [400, 401, 403, 404, 410, 422].contains(status) || (300..<400).contains(status)
        case .invalidSetup, .missingSecret, .redirected, .pageNotReturned: return true
        case .partialDelivery(_, _, _, let underlying, _): return underlying.isPermanent
        case .vaultUnavailable, .writeFailed, .networkFailed: return false
        }
    }

    var resumeToken: String? {
        guard case .partialDelivery(_, _, _, _, let resume) = self else { return nil }
        return resume
    }

    public var errorDescription: String? {
        switch self {
        case .vaultUnavailable(let name, let path):
            let where_ = path.isEmpty ? name : path
            return "Parola couldn't reach \(where_). Pick the folder again in Send To settings."
        case .writeFailed(let path, let reason):
            return "Parola couldn't write to \(path). \(reason)"
        case .httpStatus(let name, let status, let detail):
            let tail = detail.isEmpty ? "" : " \(detail)"
            return "\(name) answered HTTP \(status).\(tail)"
        case .networkFailed(let host, let failure):
            return "Parola couldn't reach \(host). \(failure.message)"
        case .missingSecret(let name):
            return "\(name) has no saved key. Enter it again in Send To settings."
        case .invalidSetup(let name, let problem):
            return "\(name) isn't set up correctly. \(problem.message)"
        case .redirected(let name, let status):
            return "\(name) has moved to another address (HTTP \(status)). Update its address in Send To settings."
        case .pageNotReturned(let name):
            return "\(name) didn't send back the new page, so Parola stopped rather than make a second one."
        case .partialDelivery(let name, let sent, let total, let underlying, _):
            return "\(name) got \(sent) of \(total) blocks before it failed, and the page stays there. \(underlying.localizedDescription)"
        }
    }
}

/// A destination's stored settings, held as plain JSON so a kind this build does not implement
/// re-encodes with the same values. Key order is not kept, and every number travels as a `Double`.
public enum DestinationConfig: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([DestinationConfig])
    case object([String: DestinationConfig])

    public var object: [String: DestinationConfig]? {
        guard case .object(let fields) = self else { return nil }
        return fields
    }

    public var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([DestinationConfig].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: DestinationConfig].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unsupported JSON value in a destination config"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// A stored destination: the kind it was written as, and its settings.
public enum AnyDestination: Codable, Sendable, Identifiable {
    case obsidianFolder(ObsidianVaultFolderDestination)
    case obsidianREST(ObsidianLocalRESTDestination)
    case webhook(WebhookDestination)
    case notion(NotionDestination)
    /// Test mode only: a destination that records what it was handed and writes nothing.
    case mock(MockDestination)
    /// A kind this build cannot run. Kept verbatim so it is still there after a round trip.
    case unsupported(kind: String, config: DestinationConfig)

    private enum CodingKeys: String, CodingKey {
        case kind
        case config
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let config = try container.decodeIfPresent(DestinationConfig.self, forKey: .config) ?? .object([:])
        self = DestinationRegistry.decode(kind: kind, config: config)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let stored = DestinationRegistry.encode(self)
        try container.encode(stored.kind, forKey: .kind)
        try container.encode(stored.config, forKey: .config)
    }

    /// The destination this build can run, or nil for a kind it cannot.
    public var destination: (any DeliveryDestination)? {
        switch self {
        case .obsidianFolder(let destination): return destination
        case .obsidianREST(let destination): return destination
        case .webhook(let destination): return destination
        case .notion(let destination): return destination
        case .mock(let destination): return destination
        case .unsupported: return nil
        }
    }

    public var kind: DestinationKind? {
        switch self {
        case .obsidianFolder, .mock: return .obsidianFolder
        case .obsidianREST: return .obsidianREST
        case .webhook: return .webhook
        case .notion: return .notion
        case .unsupported(let raw, _): return DestinationKind(rawValue: raw)
        }
    }

    /// Whether this destination belongs in the stored list. A mock lives only as long as the
    /// process that installed it, so it is never written.
    public var isPersistable: Bool {
        if case .mock = self { return false }
        return true
    }

    public var id: UUID { destination?.id ?? Self.fallbackID(for: self) }
    public var name: String { destination?.name ?? kind?.displayName ?? "" }
    public var isEnabled: Bool { destination?.isEnabled ?? false }
    public var autoSend: Bool { destination?.autoSend ?? false }
    public var categories: Set<EntryCategory> { destination?.categories ?? [] }
    public var titleFormat: TitleFormat { destination?.titleFormat ?? .title }

    /// The Keychain references this destination keeps secrets under.
    public var secretRefs: [String] {
        switch self {
        case .obsidianREST(let value): return value.secretRefs
        case .webhook(let value): return value.secretRefs
        case .notion(let value): return value.secretRefs
        case .obsidianFolder, .mock, .unsupported: return []
        }
    }

    /// The same destination wired to this environment's secrets and transport.
    public func bound(to environment: DeliveryEnvironment) -> AnyDestination {
        switch self {
        case .obsidianREST(var value): value.environment = environment; return .obsidianREST(value)
        case .webhook(var value): value.environment = environment; return .webhook(value)
        case .notion(var value): value.environment = environment; return .notion(value)
        case .obsidianFolder, .mock, .unsupported: return self
        }
    }

    /// The row-level settings every destination shares, changed in place.
    public func updating(
        isEnabled: Bool? = nil,
        autoSend: Bool? = nil,
        categories: Set<EntryCategory>? = nil,
        titleFormat: TitleFormat? = nil
    ) -> AnyDestination {
        func apply<D: DeliveryDestinationSettings>(_ value: D) -> D {
            var copy = value
            if let isEnabled { copy.isEnabled = isEnabled }
            if let autoSend { copy.autoSend = autoSend }
            if let categories { copy.categories = categories }
            if let titleFormat { copy.titleFormat = titleFormat }
            return copy
        }
        switch self {
        case .obsidianFolder(let value): return .obsidianFolder(apply(value))
        case .obsidianREST(let value): return .obsidianREST(apply(value))
        case .webhook(let value): return .webhook(apply(value))
        case .notion(let value): return .notion(apply(value))
        case .mock(let value): return .mock(apply(value))
        case .unsupported: return self
        }
    }

    /// An unsupported entry keeps the id its config carries, so a build that does implement the
    /// kind recognises the same destination.
    private static func fallbackID(for destination: AnyDestination) -> UUID {
        guard case .unsupported(let kind, let config) = destination else { return UUID() }
        if let stored = config.object?["id"]?.string, let id = UUID(uuidString: stored) { return id }
        return stableID(kind: kind, config: config)
    }

    private static func stableID(kind: String, config: DestinationConfig) -> UUID {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let material = kind + ((try? String(decoding: JSONEncoder().encode(config), as: UTF8.self)) ?? "")
        for byte in material.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8((hash >> (8 * UInt64(index))) & 0xFF)
            bytes[index + 8] = bytes[index] ^ 0x5A
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// Turns a stored `{kind, config}` pair into a destination and back. A kind this build does not
/// implement, and a config it cannot read, both come back as ``AnyDestination/unsupported(kind:config:)``
/// rather than failing the whole list.
public enum DestinationRegistry {
    public static func decode(kind: String, config: DestinationConfig) -> AnyDestination {
        let decoded: AnyDestination?
        switch DestinationKind(rawValue: kind) {
        case .obsidianFolder: decoded = (try? decodeConfig(config)).map(AnyDestination.obsidianFolder)
        case .obsidianREST: decoded = (try? decodeConfig(config)).map(AnyDestination.obsidianREST)
        case .webhook: decoded = (try? decodeConfig(config)).map(AnyDestination.webhook)
        case .notion: decoded = (try? decodeConfig(config)).map(AnyDestination.notion)
        case nil: decoded = nil
        }
        return decoded ?? .unsupported(kind: kind, config: config)
    }

    public static func encode(_ destination: AnyDestination) -> (kind: String, config: DestinationConfig) {
        switch destination {
        case .obsidianFolder(let value):
            return (DestinationKind.obsidianFolder.rawValue, encodeConfig(value))
        case .obsidianREST(let value):
            return (DestinationKind.obsidianREST.rawValue, encodeConfig(value))
        case .webhook(let value):
            return (DestinationKind.webhook.rawValue, encodeConfig(value))
        case .notion(let value):
            return (DestinationKind.notion.rawValue, encodeConfig(value))
        case .mock(let value):
            return (DestinationKind.obsidianFolder.rawValue, encodeConfig(value.asObsidianDestination))
        case .unsupported(let kind, let config):
            return (kind, config)
        }
    }

    static func decodeConfig<T: Decodable>(_ config: DestinationConfig) throws -> T {
        let data = try encoder.encode(config)
        return try decoder.decode(T.self, from: data)
    }

    static func encodeConfig<T: Encodable>(_ value: T) -> DestinationConfig {
        guard let data = try? encoder.encode(value),
              let config = try? decoder.decode(DestinationConfig.self, from: data) else {
            return .object([:])
        }
        return config
    }

    // The config travels as its own JSON document, so its coding never picks up the strategy of
    // whichever encoder writes the list around it.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
