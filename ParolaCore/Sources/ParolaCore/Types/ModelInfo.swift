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

public extension ModelInfo {
    /// Curated default catalog. Used when offline or before the remote config has been fetched.
    static let defaultCatalog: [ModelInfo] = [
        ModelInfo(
            name: "openai_whisper-tiny",
            label: "Whisper Tiny",
            approximateSizeBytes: 75 * 1_000_000,
            isMultilingual: true,
            isInstalled: false
        ),
        ModelInfo(
            name: "openai_whisper-tiny.en",
            label: "Whisper Tiny (English)",
            approximateSizeBytes: 75 * 1_000_000,
            isMultilingual: false,
            isInstalled: false
        ),
        ModelInfo(
            name: "openai_whisper-base",
            label: "Whisper Base",
            approximateSizeBytes: 145 * 1_000_000,
            isMultilingual: true,
            isInstalled: false
        ),
        ModelInfo(
            name: "openai_whisper-small",
            label: "Whisper Small",
            approximateSizeBytes: 480 * 1_000_000,
            isMultilingual: true,
            isInstalled: false
        ),
        ModelInfo(
            name: "openai_whisper-large-v3_turbo",
            label: "Whisper Large v3 Turbo (recommended)",
            approximateSizeBytes: 1_600 * 1_000_000,
            isMultilingual: true,
            isInstalled: false
        ),
        ModelInfo(
            name: "openai_whisper-large-v3",
            label: "Whisper Large v3 (highest accuracy)",
            approximateSizeBytes: 3_000 * 1_000_000,
            isMultilingual: true,
            isInstalled: false
        ),
        ModelInfo(
            name: "distil-whisper_distil-large-v3",
            label: "Distil Whisper Large v3 (English, fast)",
            approximateSizeBytes: 1_500 * 1_000_000,
            isMultilingual: false,
            isInstalled: false
        ),
    ]
}
