import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaDictation

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
    func uninstalledModelResets() async {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let model = makeModel(defaults)
        await model.awaitModelListRefresh()

        defaults.set("totally-uninstalled-model", forKey: "selectedModel")
        model.reloadSettings()
        await model.awaitModelListRefresh()

        #expect(model.selectedModel != "totally-uninstalled-model")
        #expect(model.availableModels.contains { $0.name == model.selectedModel })
    }

    @Test("the model list lands even when the first scan has to go to disk")
    func modelListLandsAfterOffMainScan() async {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let model = makeModel(defaults)

        model.refreshModelList()
        await model.awaitModelListRefresh()

        #expect(!model.availableModels.isEmpty)
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

    @Test("the microphone recording options persist through their didSets")
    func recordingOptionsPersist() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let model = makeModel(defaults)

        model.recordingMaxMinutes = 30
        model.recordingCountInSeconds = 3
        model.autoMuteWhileRecording = true
        model.autoPauseMediaWhileRecording = true

        #expect(defaults.integer(forKey: "recordingMaxMinutes") == 30)
        #expect(defaults.integer(forKey: "recordingCountInSeconds") == 3)
        #expect(defaults.bool(forKey: "autoMuteWhileRecording") == true)
        #expect(defaults.bool(forKey: "autoPauseMediaWhileRecording") == true)
    }

    @Test("reloadSettings re-reads the microphone recording options")
    func reloadReadsRecordingOptions() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let model = makeModel(defaults)
        #expect(model.recordingMaxMinutes == 0)
        #expect(model.autoMuteWhileRecording == false)

        defaults.set(45, forKey: "recordingMaxMinutes")
        defaults.set(5, forKey: "recordingCountInSeconds")
        defaults.set(true, forKey: "autoMuteWhileRecording")
        defaults.set(true, forKey: "autoPauseMediaWhileRecording")
        model.reloadSettings()

        #expect(model.recordingMaxMinutes == 45)
        #expect(model.recordingCountInSeconds == 5)
        #expect(model.autoMuteWhileRecording == true)
        #expect(model.autoPauseMediaWhileRecording == true)
    }

    @Test("resetTestState restores the microphone recording options to their defaults")
    func resetTestStateRestoresRecordingOptions() async throws {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let bootstrap = AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("reset-recopt"),
            defaultsOverride: defaults,
            sideEffects: [],
            filePicker: TestFilePicker()
        )
        let model = AppModel(bootstrap: bootstrap)
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let reset = try #require(server.lifecycleCommands().first { $0.name == "resetTestState" })

        model.recordingMaxMinutes = 60
        model.recordingCountInSeconds = 3
        model.autoMuteWhileRecording = true
        model.autoPauseMediaWhileRecording = true

        _ = try await reset.handler(reset.validate(AutomationArgs([:])), context)
        withExtendedLifetime(server) {}

        #expect(model.recordingMaxMinutes == 0)
        #expect(model.recordingCountInSeconds == 0)
        #expect(model.autoMuteWhileRecording == false)
        #expect(model.autoPauseMediaWhileRecording == false)
    }

    @Test("turning karaoke off leaves wordTimestamps as the user set it")
    func karaokeOffKeepsWordTimestamps() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let model = makeModel(defaults)
        model.wordTimestamps = true

        model.karaokeHighlight = false

        #expect(model.wordTimestamps == true)
        #expect(defaults.bool(forKey: "wordTimestamps") == true)
    }

    @Test("bridge reload action starts/stops only on a normal launch that wired the bridge")
    func bridgeReloadActionMatrix() {
        let bridge: Set<BootstrapSideEffect> = [.automationBridge]
        #expect(AppModel.bridgeReloadAction(sideEffects: bridge, mode: .normal, enabled: true, running: false) == .start)
        #expect(AppModel.bridgeReloadAction(sideEffects: bridge, mode: .normal, enabled: false, running: true) == .stop)
        #expect(AppModel.bridgeReloadAction(sideEffects: bridge, mode: .normal, enabled: true, running: true) == .keep)
        #expect(AppModel.bridgeReloadAction(sideEffects: bridge, mode: .normal, enabled: false, running: false) == .keep)
        #expect(AppModel.bridgeReloadAction(sideEffects: [], mode: .normal, enabled: true, running: false) == .keep)
        #expect(AppModel.bridgeReloadAction(sideEffects: bridge, mode: .test, enabled: false, running: true) == .keep)
        #expect(AppModel.bridgeReloadAction(sideEffects: bridge, mode: .test, enabled: true, running: false) == .keep)
    }

    @Test("reloadSettings leaves the test-mode bridge alone")
    func reloadKeepsTestModeBridge() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        defaults.set(false, forKey: "automationBridgeEnabled")
        let bootstrap = AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("reload-bridge"),
            defaultsOverride: defaults,
            sideEffects: [.automationBridge],
            filePicker: TestFilePicker()
        )
        let model = AppModel(bootstrap: bootstrap)
        #expect(model.automationBridgeRunning == false)

        defaults.set(true, forKey: "automationBridgeEnabled")
        model.reloadSettings()

        #expect(model.automationBridgeRunning == false)
    }

    @Test("reloadSettings never starts the bridge when the launch didn't wire it")
    func reloadWithoutBridgeSideEffectDoesNotStart() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let model = makeModel(defaults)
        defaults.set(true, forKey: "automationBridgeEnabled")

        model.reloadSettings()

        #expect(model.automationBridgeRunning == false)
    }

    @Test("reloading clears in-memory snippets once the defaults key is gone")
    func snippetsResetWhenKeyAbsent() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let model = makeModel(defaults)
        model.snippets = [Snippet(trigger: "omw", replacement: "on my way")]

        defaults.removeObject(forKey: AppModel.snippetsDefaultsKey)
        model.loadSnippets()

        #expect(model.snippets.isEmpty)
    }

    @Test("reloading clears in-memory correction rules once the defaults key is gone")
    func correctionRulesResetWhenKeyAbsent() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let model = makeModel(defaults)
        model.correctionRules = [CorrectionRule(from: "teh", to: "the")]

        defaults.removeObject(forKey: AppModel.correctionRulesDefaultsKey)
        model.loadCorrectionRules()

        #expect(model.correctionRules.isEmpty)
    }

    @Test("reloading clears in-memory auto-export rules once the defaults key is gone")
    func autoExportRulesResetWhenKeyAbsent() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let model = makeModel(defaults)
        model.autoExportRules = [AutoExportRule(sourceExtensions: ["wav"], outputFormats: [.txt])]

        defaults.removeObject(forKey: "autoExportRules")
        model.loadAutoExportRules()

        #expect(model.autoExportRules.isEmpty)
    }
}
