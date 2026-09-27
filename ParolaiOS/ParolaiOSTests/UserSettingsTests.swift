import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("UserSettings language mapping")
@MainActor
struct UserSettingsTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    }

    @Test("a managed default model is the first-launch pick")
    func managedDefaultModel() {
        let managed = ManagedConfiguration(plistOverride: ["defaultModel": "openai_whisper-base"])
        #expect(UserSettings.defaultModelID(configuration: managed, isInstalled: { _ in false }) == "openai_whisper-base")
    }

    @Test("an installed recommended Whisper is the default")
    func installedRecommendedIsTheDefault() {
        let turbo = "openai_whisper-large-v3_turbo"
        let id = UserSettings.defaultModelID(
            configuration: ManagedConfiguration(plistOverride: [:]), isInstalled: { $0 == turbo }
        )
        #expect(id == turbo)
    }

    @Test("a default that cannot run a live take gives way to the smallest Whisper")
    func nonStreamingDefaultFallsBack() {
        let id = UserSettings.defaultModelID(
            configuration: ManagedConfiguration(plistOverride: [:]), isInstalled: { _ in false }
        )
        #expect(ModelCatalog.canStream(id: id))
        #expect(id == ModelCatalog.fallbackModelID)
    }

    @Test("language defaults to nil when nothing is stored")
    func defaultsToNil() {
        let settings = UserSettings(defaults: freshDefaults())
        #expect(settings.language == nil)
    }

    @Test("setting a code exposes it through language")
    func setsCode() {
        let settings = UserSettings(defaults: freshDefaults())
        settings.language = "it"
        #expect(settings.language == "it")
    }

    @Test("setting language to nil clears the stored value")
    func clearsOnNil() {
        let settings = UserSettings(defaults: freshDefaults())
        settings.language = "de"
        settings.language = nil
        #expect(settings.language == nil)
    }

    @Test("an empty stored string reads back as nil")
    func emptyStringIsNil() {
        let defaults = freshDefaults()
        defaults.set("", forKey: "selectedLanguageRaw")
        let settings = UserSettings(defaults: defaults)
        #expect(settings.language == nil)
    }

    @Test("a stored code is read back on init")
    func readsStoredCode() {
        let defaults = freshDefaults()
        defaults.set("fr", forKey: "selectedLanguageRaw")
        let settings = UserSettings(defaults: defaults)
        #expect(settings.language == "fr")
    }

    @Test("a programmatic write notifies observers")
    func writeIsObservable() async {
        let settings = UserSettings(defaults: freshDefaults())
        await confirmation("observation fires on write") { fired in
            withObservationTracking {
                _ = settings.translate
            } onChange: {
                fired()
            }
            settings.translate = true
        }
    }

    @Test("a programmatic write persists to the injected store")
    func writePersistsToStore() {
        let defaults = freshDefaults()
        let settings = UserSettings(defaults: defaults)
        settings.translate = true
        settings.modelName = "openai_whisper-large-v3"
        #expect(defaults.bool(forKey: "translate"))
        #expect(defaults.string(forKey: "selectedModel") == "openai_whisper-large-v3")
    }
}
