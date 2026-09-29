import Foundation

/// Records what the mock destinations were handed, and how many times each of them should fail
/// before it starts working. One recorder per test; ``shared`` is the one the bridge drives.
public actor MockDeliveryRecorder {
    public static let shared = MockDeliveryRecorder()

    private var payloads: [DeliveryPayload] = []
    private var issued: [DeliveryReceipt] = []
    private var failuresLeft: [UUID: Int] = [:]
    private var unreachable: Set<UUID> = []
    private var checks = 0

    public init() {}

    public func setFailures(_ count: Int, for destinationID: UUID) {
        failuresLeft[destinationID] = max(0, count)
    }

    /// An unreachable mock fails its reachability check and every delivery, like a vault on an ejected drive.
    public func setReachable(_ reachable: Bool, for destinationID: UUID) {
        if reachable { unreachable.remove(destinationID) } else { unreachable.insert(destinationID) }
    }

    public func reset() {
        payloads.removeAll()
        issued.removeAll()
        failuresLeft.removeAll()
        unreachable.removeAll()
        checks = 0
    }

    /// How many reachability checks the mocks answered.
    public func reachabilityChecks() -> Int { checks }

    func checkReachable(_ destination: MockDestination) throws {
        checks += 1
        if unreachable.contains(destination.id) {
            throw DeliveryError.vaultUnavailable(destination.name, "")
        }
    }

    public func recorded() -> [DeliveryPayload] { payloads }

    public func receipts() -> [DeliveryReceipt] { issued }

    func deliver(_ payload: DeliveryPayload, from destination: MockDestination) throws -> DeliveryReceipt {
        if unreachable.contains(destination.id) {
            throw DeliveryError.vaultUnavailable(destination.name, "")
        }
        if let left = failuresLeft[destination.id], left > 0 {
            failuresLeft[destination.id] = left - 1
            throw DeliveryError.writeFailed(destination.name, "the mock destination was told to fail")
        }
        payloads.append(payload)
        let receipt = DeliveryReceipt(
            destinationID: destination.id,
            destinationName: destination.name,
            deliveredAt: Date(),
            location: URL(fileURLWithPath: "/dev/null/\(destination.name)/\(payload.entryID).md")
        )
        issued.append(receipt)
        return receipt
    }
}

/// A destination that writes nothing and remembers everything. Test mode only: the bridge installs
/// one so a script can watch a delivery without a vault on disk.
public struct MockDestination: DeliveryDestination, Sendable {
    public static let kind = DestinationKind.obsidianFolder

    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var autoSend: Bool
    public var categories: Set<EntryCategory>
    public var titleFormat: TitleFormat
    public let recorder: MockDeliveryRecorder

    public init(
        id: UUID = UUID(),
        name: String = "Mock destination",
        isEnabled: Bool = true,
        autoSend: Bool = false,
        categories: Set<EntryCategory> = Set(EntryCategory.allCases),
        titleFormat: TitleFormat = .title,
        recorder: MockDeliveryRecorder = .shared
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.autoSend = autoSend
        self.categories = categories
        self.titleFormat = titleFormat
        self.recorder = recorder
    }

    public func checkReachable() async throws {
        try await recorder.checkReachable(self)
    }

    public func deliver(_ payload: DeliveryPayload) async throws -> DeliveryReceipt {
        try await recorder.deliver(payload, from: self)
    }

    /// What a mock stores as. A mock only lives for as long as the process does, so the list it is
    /// in persists the Obsidian destination it stands in for.
    var asObsidianDestination: ObsidianVaultFolderDestination {
        ObsidianVaultFolderDestination(
            id: id,
            name: name,
            isEnabled: isEnabled,
            autoSend: autoSend,
            categories: categories,
            titleFormat: titleFormat,
            vaultBookmark: Data(),
            vaultPath: ""
        )
    }
}
