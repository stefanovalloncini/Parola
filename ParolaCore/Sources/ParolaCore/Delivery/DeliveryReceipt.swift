import Foundation

/// What one successful delivery left behind. Receipts are appended to the entry's manifest, so
/// the app can say where a transcript was sent and open it again.
public struct DeliveryReceipt: Codable, Sendable, Equatable, Hashable {
    public var destinationID: UUID
    public var destinationName: String
    public var deliveredAt: Date
    public var location: URL?

    public init(destinationID: UUID, destinationName: String, deliveredAt: Date, location: URL?) {
        self.destinationID = destinationID
        self.destinationName = destinationName
        self.deliveredAt = deliveredAt
        self.location = location
    }
}
