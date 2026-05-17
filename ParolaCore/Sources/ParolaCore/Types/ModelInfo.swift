import Foundation

public struct ModelInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }

    /// WhisperKit variant identifier, e.g. "openai_whisper-tiny".
    public var name: String

    /// Human-readable label, e.g. "Whisper Tiny".
    public var label: String

    /// Approximate on-disk size in bytes (best-effort; actual size determined after download).
    public var approximateSizeBytes: Int?

    /// Whether the model is multilingual or English-only.
    public var isMultilingual: Bool

    /// Whether the model is currently installed in the local cache.
    public var isInstalled: Bool

    /// On-disk path if installed.
    public var installedURL: URL?

    public init(
        name: String,
        label: String,
        approximateSizeBytes: Int?,
        isMultilingual: Bool,
        isInstalled: Bool,
        installedURL: URL? = nil
    ) {
        self.name = name
        self.label = label
        self.approximateSizeBytes = approximateSizeBytes
        self.isMultilingual = isMultilingual
        self.isInstalled = isInstalled
        self.installedURL = installedURL
    }
}

