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

/// Wraps a language code for logging. An unrecognized code renders as the allowlist's
/// fallback, never as the string it was given.
public struct LanguageToken: LogSafe {
    private let code: String
    public var logToken: String { LogAllowlist.languageCode(code) }
    public init(_ code: String) { self.code = code }
}

extension EngineID: LogSafe {
    public var logToken: String { LogAllowlist.engineID(rawValue) }
}

extension CloudLLMProviderID: LogSafe {
    public var logToken: String { LogAllowlist.providerID(rawValue) }
}

extension ParolaFeature: LogSafe {
    public var logToken: String { rawValue }
}

extension ModelVariant: LogSafe {
    public var logToken: String { LogAllowlist.modelID(id) }
}

extension ExportFormat: LogSafe {
    public var logToken: String { rawValue }
}

extension EntryCategory: LogSafe {
    public var logToken: String { rawValue }
}

extension BatchJob.Status: LogSafe {
    public var logToken: String { rawValue }
}

extension TranscribeStage: LogSafe {
    public var logToken: String {
        switch self {
        case .preparingAudio: return "preparingAudio"
        case .transcribing: return "transcribing"
        }
    }
}

extension SystemAudioRecordingPermission: LogSafe {
    public var logToken: String {
        switch self {
        case .granted: return "granted"
        case .undetermined: return "undetermined"
        case .denied: return "denied"
        }
    }
}

extension Int: LogSafe {
    public var logToken: String { String(self) }
}

extension Int64: LogSafe {
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
