import Foundation

/// A value that is safe to write into a diagnostics log: structural facts only,
/// never transcript text, file names, or user paths. `String` deliberately does
/// not conform — vetted types opt in explicitly.
public protocol LogSafe: Sendable {
    var logToken: String { get }
}

/// Wraps a model identifier for logging. Retire this once model ids become a
/// dedicated type that can conform to `LogSafe` directly.
public struct ModelToken: LogSafe {
    private let id: String
    public var logToken: String { LogAllowlist.modelID(id) }
    public init(_ id: String) { self.id = id }
}

extension EngineID: LogSafe {
    public var logToken: String { LogAllowlist.engineID(rawValue) }
}

extension ParolaFeature: LogSafe {
    public var logToken: String { rawValue }
}

extension Int: LogSafe {
    public var logToken: String { String(self) }
}

extension Bool: LogSafe {
    public var logToken: String { self ? "true" : "false" }
}

extension Double: LogSafe {
    public var logToken: String { LogDecimal.twoPlaces(self) }
}

extension UUID: LogSafe {
    public var logToken: String { String(uuidString.prefix(8)) }
}
