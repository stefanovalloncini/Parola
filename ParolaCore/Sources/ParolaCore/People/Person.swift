import Foundation

public struct Person: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var lastUsedAt: Date
    public var usageCount: Int
    /// Index into the speaker palette the app draws chips with, fixed when the person is created.
    public var colorIndex: Int
    /// Whether this person is you. At most one person in a directory is.
    public var isMe: Bool

    public init(
        id: UUID = UUID(), name: String, lastUsedAt: Date = Date(), usageCount: Int = 1, colorIndex: Int = 0, isMe: Bool = false
    ) {
        self.id = id
        self.name = name
        self.lastUsedAt = lastUsedAt
        self.usageCount = usageCount
        self.colorIndex = colorIndex
        self.isMe = isMe
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, lastUsedAt, usageCount, colorIndex, isMe
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        lastUsedAt = try c.decode(Date.self, forKey: .lastUsedAt)
        usageCount = try c.decode(Int.self, forKey: .usageCount)
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        isMe = try c.decodeIfPresent(Bool.self, forKey: .isMe) ?? false
    }
}

public extension Person {
    /// The form two names are compared in: trimmed, composition-folded, lowercased. The store and
    /// the app both match on this, so "josé" and "Jose\u{0301}" are one person everywhere.
    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .localizedLowercase
    }
}
