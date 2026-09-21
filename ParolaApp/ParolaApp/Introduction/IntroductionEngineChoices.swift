import Foundation
import ParolaCore

/// The at most two engines the introduction offers: Apple's built-in one and the catalog's recommended Whisper, minus an uninstalled Whisper when downloads are barred.
enum IntroductionEngineChoices {
    /// Apple Speech is `.recommended` too — for its own engine — so the catalog's pick is the recommended variant that isn't it.
    static func isRecommended(_ variant: ModelVariant) -> Bool {
        variant.category == .recommended && variant.engineID != .appleSpeech
    }

    static func compute(
        catalog: [ModelVariant],
        managed: ManagedConfiguration,
        isInstalled: (String) -> Bool
    ) -> [ModelVariant] {
        let allowed = managed.filterAllowed(catalog)
        let appleSpeech = allowed.first { $0.engineID == .appleSpeech }
        let recommended = allowed.first(where: isRecommended)
        let downloadable = managed.disableModelDownloads
            ? recommended.flatMap { isInstalled($0.id) ? $0 : nil }
            : recommended
        return [appleSpeech, downloadable].compactMap { $0 }
    }
}
