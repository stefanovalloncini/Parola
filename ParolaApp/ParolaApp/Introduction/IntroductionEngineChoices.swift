import Foundation
import ParolaCore

/// The at most two engines the introduction offers: the one built into macOS, and the Whisper the
/// catalog recommends. A deployment that bars downloads only keeps the Whisper it already has.
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
