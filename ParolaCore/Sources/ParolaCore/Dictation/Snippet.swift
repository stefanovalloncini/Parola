import Foundation

public struct Snippet: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var trigger: String
    public var replacement: String
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        trigger: String,
        replacement: String,
        enabled: Bool = true
    ) {
        self.id = id
        self.trigger = trigger
        self.replacement = replacement
        self.enabled = enabled
    }
}
