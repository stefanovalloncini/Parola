import Foundation

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        modelName = defaults.string(forKey: "selectedModel") ?? "openai_whisper-tiny"
        languageRaw = defaults.string(forKey: "selectedLanguageRaw") ?? ""
        translate = defaults.bool(forKey: "translate")
        wordTimestamps = defaults.object(forKey: "wordTimestamps") == nil ? true : defaults.bool(forKey: "wordTimestamps")
        initialPrompt = defaults.string(forKey: "initialPrompt") ?? ""
        onboardingComplete = defaults.bool(forKey: "onboardingComplete")
    }

    var language: String? {
        get { languageRaw.isEmpty ? nil : languageRaw }
        set { languageRaw = newValue ?? "" }
    }
}
