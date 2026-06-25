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

    @Test("reloadObservedSetting syncs an arbitrary writable key into its live property")
    func reloadObservedSettingSyncsAnyKey() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let model = makeModel(defaults)
        #expect(model.autoTitleEntries == false)
        #expect(model.wordTimestamps == false)
        #expect(model.translate == false)

        defaults.set(true, forKey: "autoTitleEntries")
        model.reloadObservedSetting(key: "autoTitleEntries")
        #expect(model.autoTitleEntries == true)

        defaults.set(true, forKey: "wordTimestamps")
        model.reloadObservedSetting(key: "wordTimestamps")
        #expect(model.wordTimestamps == true)

        defaults.set(true, forKey: "translate")
        model.reloadObservedSetting(key: "translate")
        #expect(model.translate == true)
    }

    @Test("inputDeviceUID persists to defaults and reloadSettings re-reads it")
    func inputDeviceUIDPersistsAndReloads() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let model = makeModel(defaults)
        #expect(model.inputDeviceUID == "")
        #expect(model.preferredInputDeviceUID == nil)

        model.inputDeviceUID = "BuiltInMicrophoneDevice"
        #expect(defaults.string(forKey: "inputDeviceUID") == "BuiltInMicrophoneDevice")
        #expect(model.preferredInputDeviceUID == "BuiltInMicrophoneDevice")

        defaults.set("USBAudioDevice", forKey: "inputDeviceUID")
        model.reloadSettings()
        #expect(model.inputDeviceUID == "USBAudioDevice")
        #expect(model.preferredInputDeviceUID == "USBAudioDevice")
    }

    @Test("preferredInputDeviceUID maps an empty selection to nil (system default)")
    func preferredInputDeviceUIDMapsEmptyToNil() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let model = makeModel(defaults)

        model.inputDeviceUID = ""
        #expect(model.preferredInputDeviceUID == nil)
        model.inputDeviceUID = "SomeDevice"
        #expect(model.preferredInputDeviceUID == "SomeDevice")
        model.inputDeviceUID = ""
        #expect(model.preferredInputDeviceUID == nil)
    }

    @Test("resetTestState restores inputDeviceUID to the system default")
    func resetTestStateRestoresInputDevice() async throws {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let bootstrap = AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("reset-mic"),
            defaultsOverride: defaults,
            sideEffects: [],
            filePicker: TestFilePicker()
        )
        let model = AppModel(bootstrap: bootstrap)
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let reset = try #require(server.lifecycleCommands().first { $0.name == "resetTestState" })

        model.inputDeviceUID = "USBAudioDevice"
        #expect(model.preferredInputDeviceUID == "USBAudioDevice")

        _ = try await reset.handler(reset.validate(AutomationArgs([:])), context)
        withExtendedLifetime(server) {}

        #expect(model.inputDeviceUID == "")
        #expect(model.preferredInputDeviceUID == nil)
    }

    @Test("resetTestState restores live settings properties, not just UserDefaults")
    func resetTestStateRestoresLiveSettings() async throws {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let bootstrap = AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("reset-live"),
            defaultsOverride: defaults,
            sideEffects: [],
            filePicker: TestFilePicker()
        )
        let model = AppModel(bootstrap: bootstrap)
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let reset = try #require(server.lifecycleCommands().first { $0.name == "resetTestState" })

        model.selectedModel = "openai_whisper-base"
        model.selectedLanguage = "it"
        model.translate = true
        model.wordTimestamps = true

        _ = try await reset.handler(reset.validate(AutomationArgs([:])), context)
        withExtendedLifetime(server) {}

        #expect(model.selectedModel == "openai_whisper-tiny")
        #expect(model.selectedLanguage == nil)
        #expect(model.translate == false)
        #expect(model.wordTimestamps == false)
    }
}
