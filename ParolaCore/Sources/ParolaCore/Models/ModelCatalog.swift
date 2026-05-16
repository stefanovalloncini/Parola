import Foundation

public enum ModelCatalog {
    public static let all: [ModelVariant] = [
        ModelVariant(
            id: "openai_whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            tagline: "Best balance for most people",
            engineID: .whisperKit,
            sizeBytes: 1_600_000_000,
            downloadSource: whisperKitSource("openai_whisper-large-v3-turbo"),
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
                subpath: ""
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

    public static func variant(id: String) -> ModelVariant? {
        all.first { $0.id == id }
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

    public static func groupedForPicker() -> [(ModelCategory, [ModelVariant])] {
        let grouped = Dictionary(grouping: all) { $0.category }
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
