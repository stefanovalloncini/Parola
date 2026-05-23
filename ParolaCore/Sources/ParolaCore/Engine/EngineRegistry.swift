import Foundation

public actor EngineRegistry {
    public static let shared = EngineRegistry()

    public typealias Factory = @Sendable (ModelStore) -> any Transcriber
    public typealias Downloader = @Sendable (
        String,
        ModelStore,
        (@Sendable (Double) -> Void)?
    ) async throws -> URL

    private struct Entry {
        let capabilities: EngineCapabilities
        let factory: Factory
        let downloader: Downloader?
    }

    private var entries: [EngineID: Entry] = [:]

    public init() {}

    public func register(
        engineID: EngineID,
        capabilities: EngineCapabilities,
        factory: @escaping Factory,
        downloader: Downloader? = nil
    ) {
        entries[engineID] = Entry(
            capabilities: capabilities,
            factory: factory,
            downloader: downloader
        )
    }

    /// Test-only seam. Calling this on `EngineRegistry.shared` wipes engine registrations
    /// for the whole process. Prefer a local `EngineRegistry()` instance in tests.
    public func unregisterAll() {
        entries.removeAll()
    }

    public func transcriber(for engineID: EngineID, store: ModelStore) throws -> any Transcriber {
        guard let entry = entries[engineID] else {
            throw ParolaError.engineNotRegistered(engineID.rawValue)
        }
        return entry.factory(store)
    }

    public func capabilities(for engineID: EngineID) -> EngineCapabilities? {
        entries[engineID]?.capabilities
    }

    public func downloader(for engineID: EngineID) -> Downloader? {
        entries[engineID]?.downloader
    }

    public func registeredEngines() -> [EngineID] {
        Array(entries.keys).sorted { $0.rawValue < $1.rawValue }
    }

    public func isRegistered(_ engineID: EngineID) -> Bool {
        entries[engineID] != nil
    }
}
