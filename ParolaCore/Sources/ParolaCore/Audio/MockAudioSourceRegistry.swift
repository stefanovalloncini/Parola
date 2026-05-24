import Foundation

public actor MockAudioSourceRegistry {
    public static let shared = MockAudioSourceRegistry()

    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case mic
        case system
    }

    private var fixtures: [Kind: URL] = [:]

    public init() {}

    public func install(kind: Kind?, fixtureURL: URL) {
        if let kind {
            fixtures[kind] = fixtureURL
        } else {
            for k in Kind.allCases {
                fixtures[k] = fixtureURL
            }
        }
    }

    public func clear() {
        fixtures.removeAll()
    }

    public func resolve(for kind: Kind) -> URL? {
        fixtures[kind]
    }

    public func list() -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in fixtures {
            out[k.rawValue] = v.path
        }
        return out
    }
}
