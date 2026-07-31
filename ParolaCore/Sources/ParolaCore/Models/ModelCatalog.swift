import Foundation
import FluidAudio

public enum ModelCatalog {
    public static let all: [ModelVariant] = appleSpeechVariants() + curated

    private static func appleSpeechVariants() -> [ModelVariant] {
        guard #available(macOS 26.0, iOS 26.0, *) else { return [] }
        return [
            ModelVariant(
                id: AppleSpeechTranscriber.syntheticModelID,
                displayName: "Apple Speech (system)",
                tagline: "Built into macOS · no download · 50+ locales",
                engineID: .appleSpeech,
                sizeBytes: 0,
                downloadSource: ModelDownloadSource(
                    huggingFaceRepo: "apple/speech-analyzer",
                    subpath: ""
                ),
                category: .recommended,
                speedTier: .fastest,
                qualityTier: .better,
                badges: ["No download", "System"]
            )
        ]
    }

    private static let curated: [ModelVariant] = [
        ModelVariant(
            id: "openai_whisper-large-v3_turbo",
            displayName: "Whisper Large v3 Turbo",
            tagline: "Best balance for most people",
            engineID: .whisperKit,
            sizeBytes: 1_600_000_000,
            downloadSource: whisperKitSource("openai_whisper-large-v3_turbo"),
            category: .recommended,
            speedTier: .fast,
            qualityTier: .best,
            badges: ["Multilingual", "Recommended"]
        ),
        ModelVariant(
            id: "nvidia_parakeet-tdt-0.6b-v2",
            displayName: "Parakeet TDT 0.6B v2",
            tagline: "Fastest English on Apple Silicon",
            engineID: .parakeet,
            sizeBytes: 600_000_000,
            downloadSource: ModelDownloadSource(
                huggingFaceRepo: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
                subpath: "",
                installDirectory: "FluidInference/\(Repo.parakeetV2.folderName)"
            ),
            category: .fastest,
            speedTier: .fastest,
            qualityTier: .better,
            languageScope: .only(["en"]),
            badges: ["English", "Fastest"]
        ),
        ModelVariant(
            id: "openai_whisper-large-v3",
            displayName: "Whisper Large v3",
            tagline: "Highest-accuracy multilingual",
            engineID: .whisperKit,
            sizeBytes: 3_000_000_000,
            downloadSource: whisperKitSource("openai_whisper-large-v3"),
            category: .mostAccurate,
            speedTier: .balanced,
            qualityTier: .best,
            badges: ["Multilingual"]
        ),
        ModelVariant(
            id: "openai_whisper-tiny",
            displayName: "Whisper Tiny",
            tagline: "Smallest, fastest Whisper",
            engineID: .whisperKit,
            sizeBytes: 75_000_000,
            downloadSource: whisperKitSource("openai_whisper-tiny"),
            category: .compact,
            speedTier: .fastest,
            qualityTier: .good,
            badges: ["Multilingual", "75 MB"]
        ),
        ModelVariant(
            id: "openai_whisper-base",
            displayName: "Whisper Base",
            tagline: "Small, multilingual",
            engineID: .whisperKit,
            sizeBytes: 145_000_000,
            downloadSource: whisperKitSource("openai_whisper-base"),
            category: .compact,
            speedTier: .fastest,
            qualityTier: .good,
            badges: ["Multilingual"]
        ),
        ModelVariant(
            id: "openai_whisper-small",
            displayName: "Whisper Small",
            tagline: "A step up from tiny/base",
            engineID: .whisperKit,
            sizeBytes: 480_000_000,
            downloadSource: whisperKitSource("openai_whisper-small"),
            category: .compact,
            speedTier: .fast,
            qualityTier: .good,
            badges: ["Multilingual"]
        ),
        ModelVariant(
            id: "openai_whisper-tiny.en",
            displayName: "Whisper Tiny (English)",
            tagline: "Smallest English-only Whisper",
            engineID: .whisperKit,
            sizeBytes: 75_000_000,
            downloadSource: whisperKitSource("openai_whisper-tiny.en"),
            category: .specialized,
            speedTier: .fastest,
            qualityTier: .good,
            languageScope: .only(["en"]),
            badges: ["English", "75 MB"]
        ),
        ModelVariant(
            id: "distil-whisper_distil-large-v3",
            displayName: "Distil Whisper Large v3",
            tagline: "English-only fast Whisper",
            engineID: .whisperKit,
            sizeBytes: 1_500_000_000,
            downloadSource: whisperKitSource("distil-whisper_distil-large-v3"),
            category: .specialized,
            speedTier: .fast,
            qualityTier: .better,
            languageScope: .only(["en"]),
            badges: ["English"]
        )
    ]

    private static func whisperKitSource(_ id: String) -> ModelDownloadSource {
        ModelDownloadSource(huggingFaceRepo: "argmaxinc/whisperkit-coreml", subpath: id)
    }

    /// Last-resort model when nothing better is known: smallest multilingual Whisper.
    public static let fallbackModelID = "openai_whisper-tiny"

    /// The model to use when the caller doesn't name one: the managed default if set,
    /// else the first allowed recommended variant, else the first allowed variant at all.
    public static func defaultModelID(configuration: ManagedConfiguration = .shared) -> String {
        if let managed = configuration.defaultModel, variant(id: managed) != nil {
            return managed
        }
        let allowed = configuration.filterAllowed(all)
        if let recommended = allowed.first(where: { $0.category == .recommended }) {
            return recommended.id
        }
        return allowed.first?.id ?? fallbackModelID
    }

    /// The default adjusted for a specific request: when the plain default can't honor
    /// diarization or translation (Apple Speech can't do either), falls back to the Whisper that can.
    public static func defaultModelID(
        for options: TranscriptionOptions,
        configuration: ManagedConfiguration = .shared
    ) -> String {
        let id = defaultModelID(configuration: configuration)
        guard let caps = staticCapabilities(forID: id) else { return id }
        if options.diarize && !caps.supportsDiarization { return fallbackModelID }
        if options.task == .translate && !caps.supportsTranslate { return fallbackModelID }
        return id
    }

    public static func variant(id: String) -> ModelVariant? {
        all.first { $0.id == id }
    }

    /// Best-effort suggestion for a mistyped or partial model id, e.g. the bare
    /// "parakeet-tdt-0.6b-v2" alias → "nvidia_parakeet-tdt-0.6b-v2". Nil when nothing is close,
    /// so ids for repos outside the catalog can still pass through untouched.
    public static func closestMatch(for id: String) -> ModelVariant? {
        let needle = id.lowercased()
        guard needle.count >= 4 else { return nil }
        let candidates = all.filter { $0.id.lowercased() != needle }
        if let suffix = candidates.first(where: { $0.id.lowercased().hasSuffix(needle) }) {
            return suffix
        }
        return candidates.first { $0.id.lowercased().contains(needle) }
    }

    public static func variants(for engineID: EngineID) -> [ModelVariant] {
        all.filter { $0.engineID == engineID }
    }

    public static func effectiveCapabilities(
        for variant: ModelVariant,
        registry: EngineRegistry = .shared
    ) async -> EngineCapabilities? {
        guard let base = await registry.capabilities(for: variant.engineID) else { return nil }
        return base.tightened(by: variant.languageScope)
    }

    /// Synchronous capability lookup for UI gating. Returns nil for engines this build
    /// doesn't know about — callers must handle unknown engines explicitly rather than
    /// claim a possibly-wrong default. The registry remains the source of truth at run time.
    public static func staticCapabilities(for variant: ModelVariant) -> EngineCapabilities? {
        let base: EngineCapabilities
        switch variant.engineID {
        case .whisperKit:  base = .whisperKitDefaults
        case .parakeet:    base = .parakeetDefaults
        case .appleSpeech: base = .appleSpeechDefaults
        default:           return nil
        }
        return base.tightened(by: variant.languageScope)
    }

    public static func staticCapabilities(forID id: String) -> EngineCapabilities? {
        variant(id: id).flatMap(staticCapabilities(for:))
    }

    public static func groupedForPicker(
        configuration: ManagedConfiguration = .shared
    ) -> [(ModelCategory, [ModelVariant])] {
        let grouped = Dictionary(grouping: configuration.filterAllowed(all)) { $0.category }
        return ModelCategory.allCases
            .compactMap { category in
                guard let variants = grouped[category], !variants.isEmpty else { return nil }
                let sorted = variants.sorted { a, b in
                    if a.qualityTier != b.qualityTier { return a.qualityTier > b.qualityTier }
                    return a.sizeBytes < b.sizeBytes
                }
                return (category, sorted)
            }
    }
}
