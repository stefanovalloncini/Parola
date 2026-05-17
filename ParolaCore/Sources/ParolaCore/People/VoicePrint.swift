import Foundation

public struct VoicePrint: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var embedding: [Float]
    public var sampleCount: Int
    public var lastSeen: Date

    public init(
        id: UUID = UUID(),
        name: String,
        embedding: [Float],
        sampleCount: Int = 1,
        lastSeen: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.sampleCount = sampleCount
        self.lastSeen = lastSeen
    }
}
