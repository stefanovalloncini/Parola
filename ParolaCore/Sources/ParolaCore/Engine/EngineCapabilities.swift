import Foundation

public struct EngineID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init?(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let whisperKit = EngineID("whisperkit")
    public static let parakeet = EngineID("parakeet")
}

public enum SupportedLanguages: Sendable, Hashable {
    case all
    case only(Set<String>)

    public func allows(_ language: String?) -> Bool {
        switch self {
        case .all:
            return true
        case .only(let codes):
            guard let language else { return false }
            return codes.contains(language.lowercased())
        }
    }

    public var isEnglishOnly: Bool {
        if case .only(let codes) = self, codes == ["en"] { return true }
        return false
    }
}

public struct EngineCapabilities: Sendable, Hashable {
    public let supportedLanguages: SupportedLanguages
    public let supportsTranslate: Bool
    public let supportsInitialPrompt: Bool
    public let supportsWordTimestamps: Bool
    public let supportsDiarization: Bool

    public init(
        supportedLanguages: SupportedLanguages,
        supportsTranslate: Bool,
        supportsInitialPrompt: Bool,
        supportsWordTimestamps: Bool,
        supportsDiarization: Bool
    ) {
        self.supportedLanguages = supportedLanguages
        self.supportsTranslate = supportsTranslate
        self.supportsInitialPrompt = supportsInitialPrompt
        self.supportsWordTimestamps = supportsWordTimestamps
        self.supportsDiarization = supportsDiarization
    }

    public static let whisperKitDefaults = EngineCapabilities(
        supportedLanguages: .all,
        supportsTranslate: true,
        supportsInitialPrompt: true,
        supportsWordTimestamps: true,
        supportsDiarization: true
    )

    public static let parakeetDefaults = EngineCapabilities(
        supportedLanguages: .only(["en"]),
        supportsTranslate: false,
        supportsInitialPrompt: false,
        supportsWordTimestamps: true,
        supportsDiarization: true
    )

    /// Combine engine capabilities with a per-variant language tightening.
    /// A variant may narrow language support (e.g. `whisper-tiny.en` → English-only) but never widen it.
    public func tightened(by variantScope: SupportedLanguages?) -> EngineCapabilities {
        guard let variantScope else { return self }
        let narrowed: SupportedLanguages
        switch (supportedLanguages, variantScope) {
        case (.all, let scope):
            narrowed = scope
        case (.only(let engineCodes), .only(let variantCodes)):
            narrowed = .only(engineCodes.intersection(variantCodes))
        case (.only, .all):
            narrowed = supportedLanguages
        }
        return EngineCapabilities(
            supportedLanguages: narrowed,
            supportsTranslate: supportsTranslate && !narrowed.isEnglishOnly,
            supportsInitialPrompt: supportsInitialPrompt,
            supportsWordTimestamps: supportsWordTimestamps,
            supportsDiarization: supportsDiarization
        )
    }
}
