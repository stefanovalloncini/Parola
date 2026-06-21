import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("reloadSettings")
struct ReloadSettingsTests {
    private func makeModel(_ defaults: UserDefaults) -> AppModel {
        AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("reload"))
    }

    @Test("re-reads changed keys into observed properties without a relaunch")
    func reReadsChangedKeys() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let model = makeModel(defaults)
        #expect(model.useStreaming == true)

        defaults.set(false, forKey: "useStreaming")
        defaults.set("dark", forKey: "appTheme")
        defaults.set(true, forKey: "diarize")
        model.reloadSettings()

        #expect(model.useStreaming == false)
        #expect(model.appTheme == "dark")
        #expect(model.diarize == true)
    }

    @Test("picks up appAccentColor via its storage key (which maps to appAccentRaw)")
    func accentKeyDrift() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let model = makeModel(defaults)

        defaults.set("ocean", forKey: AppAccent.storageKey)
        model.reloadSettings()

        #expect(model.appAccentRaw == "ocean")
    }

    @Test("reloading to an uninstalled model resets it to a valid one (refreshModelList ran)")
    func uninstalledModelResets() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let model = makeModel(defaults)

        defaults.set("totally-uninstalled-model", forKey: "selectedModel")
        model.reloadSettings()

        #expect(model.selectedModel != "totally-uninstalled-model")
        #expect(model.availableModels.contains { $0.name == model.selectedModel })
    }
}
