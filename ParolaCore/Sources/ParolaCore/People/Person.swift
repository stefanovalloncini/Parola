import Foundation

public struct Person: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var lastUsedAt: Date
    public var usageCount: Int

    public init(id: UUID = UUID(), name: String, lastUsedAt: Date = Date(), usageCount: Int = 1) {
        self.id = id
        self.name = name
        self.lastUsedAt = lastUsedAt
        self.usageCount = usageCount
    }
}
