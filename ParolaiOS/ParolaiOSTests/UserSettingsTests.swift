import Foundation
import Testing
@testable import Parola

@Suite("UserSettings language mapping")
@MainActor
struct UserSettingsTests {
    private static let languageKey = "selectedLanguageRaw"

    private func freshSettings() -> UserSettings {
        UserDefaults.standard.removeObject(forKey: Self.languageKey)
        return UserSettings()
    }

    @Test("language defaults to nil when nothing is stored")
    func defaultsToNil() {
        let settings = freshSettings()
        #expect(settings.language == nil)
        UserDefaults.standard.removeObject(forKey: Self.languageKey)
    }

    @Test("setting a code exposes it through language")
    func setsCode() {
        let settings = freshSettings()
        settings.language = "it"
        #expect(settings.language == "it")
        UserDefaults.standard.removeObject(forKey: Self.languageKey)
    }

    @Test("setting language to nil clears the stored value")
    func clearsOnNil() {
        let settings = freshSettings()
        settings.language = "de"
        settings.language = nil
        #expect(settings.language == nil)
        UserDefaults.standard.removeObject(forKey: Self.languageKey)
    }

    @Test("an empty stored string reads back as nil")
    func emptyStringIsNil() {
        UserDefaults.standard.set("", forKey: Self.languageKey)
        let settings = UserSettings()
        #expect(settings.language == nil)
        UserDefaults.standard.removeObject(forKey: Self.languageKey)
    }
}
