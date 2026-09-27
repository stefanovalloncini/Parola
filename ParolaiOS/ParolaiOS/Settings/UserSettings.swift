import Foundation
import SwiftUI
import ParolaCore

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .system: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
@Observable
final class UserSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var modelName: String { didSet { defaults.set(modelName, forKey: "selectedModel") } }
    private var languageRaw: String { didSet { defaults.set(languageRaw, forKey: "selectedLanguageRaw") } }
    var translate: Bool { didSet { defaults.set(translate, forKey: "translate") } }
    var wordTimestamps: Bool { didSet { defaults.set(wordTimestamps, forKey: "wordTimestamps") } }
    var initialPrompt: String { didSet { defaults.set(initialPrompt, forKey: "initialPrompt") } }
    var onboardingComplete: Bool { didSet { defaults.set(onboardingComplete, forKey: "onboardingComplete") } }
    var appearance: AppTheme { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        modelName = defaults.string(forKey: "selectedModel") ?? Self.defaultModelID()
        languageRaw = defaults.string(forKey: "selectedLanguageRaw") ?? ""
        translate = defaults.bool(forKey: "translate")
        wordTimestamps = defaults.object(forKey: "wordTimestamps") == nil ? true : defaults.bool(forKey: "wordTimestamps")
        initialPrompt = defaults.string(forKey: "initialPrompt") ?? ""
        onboardingComplete = defaults.bool(forKey: "onboardingComplete")
        appearance = AppTheme(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
    }

    /// Core's default, as long as it can run a live take: iOS records only through the streaming session.
    static func defaultModelID(
        configuration: ManagedConfiguration = .shared,
        isInstalled: (String) -> Bool = { ModelStore.shared.isInstalled($0) }
    ) -> String {
        let id = ModelCatalog.defaultModelID(
            for: TranscriptionOptions(), configuration: configuration, isInstalled: isInstalled
        )
        return ModelCatalog.canStream(id: id) ? id : ModelCatalog.fallbackModelID
    }

    var language: String? {
        get { languageRaw.isEmpty ? nil : languageRaw }
        set { languageRaw = newValue ?? "" }
    }
}
