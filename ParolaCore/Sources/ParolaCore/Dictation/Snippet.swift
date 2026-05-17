import Foundation

public struct Snippet: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var trigger: String
    public var replacement: String
    public var enabled: Bool
    /// When true, defer expansion until just before insertion. Useful for placeholders that
    /// read live state ({{CLIPBOARD}}, {{SELECTION}}, {{APP}}) and would otherwise capture
    /// stale values at transcribe time.
    public var expandAtInsert: Bool

    public init(
        id: UUID = UUID(),
        trigger: String,
        replacement: String,
        enabled: Bool = true,
        expandAtInsert: Bool = false
    ) {
        self.id = id
        self.trigger = trigger
        self.replacement = replacement
        self.enabled = enabled
        self.expandAtInsert = expandAtInsert
    }

    public enum CodingKeys: String, CodingKey {
        case id, trigger, replacement, enabled, expandAtInsert
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        trigger = try container.decode(String.self, forKey: .trigger)
        replacement = try container.decode(String.self, forKey: .replacement)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        expandAtInsert = try container.decodeIfPresent(Bool.self, forKey: .expandAtInsert) ?? false
    }
}
