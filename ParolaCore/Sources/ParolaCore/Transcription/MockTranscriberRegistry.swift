import Foundation

public actor MockTranscriberRegistry {
    public static let shared = MockTranscriberRegistry()

    private var byEngine: [EngineID: MockTranscriberResponse] = [:]
    private var globalMock: MockTranscriberResponse?

    public init() {}

    public func install(engineID: EngineID?, response: MockTranscriberResponse) {
        if let engineID {
            byEngine[engineID] = response
        } else {
            globalMock = response
        }
    }

    public func clear() {
        byEngine.removeAll()
        globalMock = nil
    }

    public func resolve(for engineID: EngineID) -> MockTranscriberResponse? {
        byEngine[engineID] ?? globalMock
    }

    public func list() -> [String] {
        var keys = byEngine.keys.map(\.rawValue).sorted()
        if globalMock != nil { keys.append("*") }
        return keys
    }
}
