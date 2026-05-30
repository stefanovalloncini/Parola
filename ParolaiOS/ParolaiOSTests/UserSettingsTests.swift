import Foundation
import Testing
@testable import Parola

@Suite("UserSettings language mapping")
@MainActor
struct UserSettingsTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID().uuidString)")!
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
}
