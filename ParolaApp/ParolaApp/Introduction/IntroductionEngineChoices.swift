import Foundation
import ParolaCore

/// The at most two engines the introduction offers: Apple's built-in one and the catalog's recommended Whisper, minus an uninstalled Whisper when downloads are barred.
enum IntroductionEngineChoices {
    static func compute(
        catalog: [ModelVariant],
        managed: ManagedConfiguration,
        isInstalled: (String) -> Bool
    ) -> [ModelVariant] {
        let allowed = managed.filterAllowed(catalog)
        let appleSpeech = allowed.first { $0.engineID == .appleSpeech }
        let recommended = allowed.first { $0.category == .recommended && $0.engineID != .appleSpeech }
        let downloadable = managed.disableModelDownloads
            ? recommended.flatMap { isInstalled($0.id) ? $0 : nil }
            : recommended
        return [appleSpeech, downloadable].compactMap { $0 }
    }
}
