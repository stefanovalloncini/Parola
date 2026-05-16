import Foundation

public actor EngineRegistry {
    public static let shared = EngineRegistry()

    public typealias Factory = @Sendable (ModelStore) -> any Transcriber

    private struct Entry {
        let capabilities: EngineCapabilities
        let factory: Factory
    }

    private var entries: [EngineID: Entry] = [:]

    public init() {}

    public func register(
        engineID: EngineID,
        capabilities: EngineCapabilities,
        factory: @escaping Factory
    ) {
        entries[engineID] = Entry(capabilities: capabilities, factory: factory)
    }

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

    public func registeredEngines() -> [EngineID] {
        Array(entries.keys).sorted { $0.rawValue < $1.rawValue }
    }

    public func isRegistered(_ engineID: EngineID) -> Bool {
        entries[engineID] != nil
    }
}
