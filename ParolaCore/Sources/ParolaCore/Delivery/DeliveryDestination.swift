import Foundation

/// The outbound integrations Parola knows the names of. Only ``obsidianFolder`` has an
/// implementation; the others exist so a stored list written by another build still decodes.
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

    public var isImplemented: Bool { self == .obsidianFolder }
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
    func deliver(_ payload: DeliveryPayload) async throws -> DeliveryReceipt
}

public extension DeliveryDestination {
    var kind: DestinationKind { Self.kind }

    func accepts(_ category: EntryCategory) -> Bool {
        categories.contains(category)
    }
}

/// Why a delivery could not be made.
public enum DeliveryError: Error, LocalizedError, Equatable {
    case vaultUnavailable(String, String)
    case writeFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .vaultUnavailable(let name, let path):
            let where_ = path.isEmpty ? name : path
            return "Parola couldn't reach \(where_). Pick the folder again in Send To settings."
        case .writeFailed(let path, let reason):
            return "Parola couldn't write to \(path). \(reason)"
        }
    }
}

/// A destination's stored settings, held as plain JSON so a kind this build does not implement
/// re-encodes exactly as it was read.
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
        case .mock(let destination): return destination
        case .unsupported: return nil
        }
    }

    public var kind: DestinationKind? {
        switch self {
        case .obsidianFolder, .mock: return .obsidianFolder
        case .unsupported(let raw, _): return DestinationKind(rawValue: raw)
        }
    }

    public var id: UUID { destination?.id ?? Self.fallbackID(for: self) }
    public var name: String { destination?.name ?? kind?.displayName ?? "" }
    public var isEnabled: Bool { destination?.isEnabled ?? false }
    public var autoSend: Bool { destination?.autoSend ?? false }
    public var categories: Set<EntryCategory> { destination?.categories ?? [] }
    public var titleFormat: TitleFormat { destination?.titleFormat ?? .title }

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
        guard DestinationKind(rawValue: kind) == .obsidianFolder,
              let destination: ObsidianVaultFolderDestination = try? decodeConfig(config) else {
            return .unsupported(kind: kind, config: config)
        }
        return .obsidianFolder(destination)
    }

    public static func encode(_ destination: AnyDestination) -> (kind: String, config: DestinationConfig) {
        switch destination {
        case .obsidianFolder(let value):
            return (DestinationKind.obsidianFolder.rawValue, encodeConfig(value))
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
