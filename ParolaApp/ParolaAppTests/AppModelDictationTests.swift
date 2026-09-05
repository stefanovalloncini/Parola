import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaDictation

@MainActor
@Suite("AppModel dictation")
struct AppModelDictationTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        temporaryDefaults()
    }

    private func makeModel() -> AppModel {
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("dictation"))
        model.dictationPerAppOverridesJSON = "{}"
        return model
    }

    @Test("persisted dictationEnabled does not auto-start the controller during init")
    func persistedDictationEnabledDoesNotAutoStartDuringInit() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "dictationEnabled")
        // skipBootstrap => sideEffects = [] (no .dictationHotkey), matching --test-mode.
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("dictation-init"))

        // The setting itself loads…
        #expect(model.dictationEnabled == true)
        // …but the controller must NOT have started during the bulk settings read. Auto-starting
        // there builds the coordinator before wireDictationController sets appModel, so in test mode
        // it wrongly selects the real inserter (PerAppTextInserter) over CapturingTextInserter and
        // dictation output never reaches CapturedInsertionStore.
        #expect(model.dictationController.isRunning == false)
    }

    @Test("dictation model warnings flag unsuitable configurations")
    func dictationModelWarningsCases() {
        let clean = AppModel.dictationModelWarnings(
            model: "openai_whisper-tiny", useStreaming: true, language: "en", isInstalled: true)
        #expect(clean.isEmpty)

        let parakeetItalian = AppModel.dictationModelWarnings(
            model: "nvidia_parakeet-tdt-0.6b-v2", useStreaming: true, language: "it", isInstalled: true)
        #expect(parakeetItalian.contains { $0.contains("English-only") })
        #expect(parakeetItalian.contains { $0.contains("live preview") })

        let streamingOff = AppModel.dictationModelWarnings(
            model: "openai_whisper-tiny", useStreaming: false, language: nil, isInstalled: true)
        #expect(streamingOff.count == 1)
        #expect(streamingOff.first?.contains("Streaming is off") == true)

        let notInstalled = AppModel.dictationModelWarnings(
            model: "openai_whisper-large-v3_turbo", useStreaming: true, language: nil, isInstalled: false)
        #expect(notInstalled.count == 1)
        #expect(notInstalled.first?.contains("downloads") == true)

        let unknown = AppModel.dictationModelWarnings(
            model: "custom-model", useStreaming: true, language: "it", isInstalled: false)
        #expect(unknown.isEmpty, "ids outside the catalog are legacy WhisperKit dirs: they stream, and no capability or size claims apply")
    }

    @Test("dictationWorkflows decodes from the per-app overrides JSON")
    func decodeWorkflows() {
        let model = makeModel()
        let payload: [String: [DictationWorkflow]] = [
            "com.apple.mail": [DictationWorkflow(promptID: "p-1", language: "en")],
        ]
        let data = DictationWorkflowMap.encode(payload)
        model.dictationPerAppOverridesJSON = String(decoding: data, as: UTF8.self)

        let map = model.dictationWorkflows()

        #expect(map["com.apple.mail"]?.first?.promptID == "p-1")
        #expect(map["com.apple.mail"]?.first?.language == "en")
    }

    @Test("dictationWorkflows reuses the cache when JSON has not changed")
    func cacheReusedAcrossCalls() {
        let model = makeModel()
        model.setDictationOverridePromptID("p-id", for: "com.apple.notes")

        let first = model.dictationWorkflows()
        let second = model.dictationWorkflows()

        #expect(first["com.apple.notes"]?.first?.promptID == "p-id")
        #expect(second == first)
    }

    @Test("changing dictationPerAppOverridesJSON invalidates the cache")
    func cacheInvalidatesOnEdit() {
        let model = makeModel()
        model.setDictationOverridePromptID("first", for: "com.apple.mail")
        _ = model.dictationWorkflows()

        model.dictationPerAppOverridesJSON = "{}"
        let after = model.dictationWorkflows()

        #expect(after.isEmpty)
    }

    @Test("setDictationOverridePromptID round-trips through the workflow map")
    func setPromptIDRoundTrip() {
        let model = makeModel()

        model.setDictationOverridePromptID("prompt-42", for: "com.apple.Notes")

        #expect(model.dictationOverridePromptID(for: "com.apple.Notes") == "prompt-42")
    }

    @Test("clearing the prompt ID removes the workflow for that bundle")
    func clearingPromptIDRemovesEntry() {
        let model = makeModel()
        model.setDictationOverridePromptID("prompt-42", for: "com.apple.Notes")

        model.setDictationOverridePromptID("", for: "com.apple.Notes")

        #expect(model.dictationWorkflows()["com.apple.Notes"] == nil)
        #expect(model.dictationOverridePromptID(for: "com.apple.Notes").isEmpty)
    }

    @Test("setDictationOverrideLanguage and read-back agree")
    func overrideLanguageRoundTrip() {
        let model = makeModel()

        model.setDictationOverrideLanguage("it", for: "com.apple.mail")

        #expect(model.dictationOverrideLanguage(for: "com.apple.mail") == "it")
    }

    @Test("setDictationOverrideInsertion stores non-default modes and returns paste otherwise")
    func overrideInsertionRoundTrip() {
        let model = makeModel()

        model.setDictationOverrideInsertion(.keystroke, for: "com.apple.mail")
        #expect(model.dictationOverrideInsertion(for: "com.apple.mail") == .keystroke)

        model.setDictationOverrideInsertion(.paste, for: "com.apple.mail")
        #expect(model.dictationOverrideInsertion(for: "com.apple.mail") == .paste)
    }

    @Test("removeDictationOverride wipes all entries for a bundle ID")
    func removeOverride() {
        let model = makeModel()
        model.setDictationOverridePromptID("prompt", for: "com.apple.mail")
        model.addDictationURLRule(for: "com.apple.mail", pattern: "gmail.com")

        model.removeDictationOverride(for: "com.apple.mail")

        #expect(model.dictationWorkflows()["com.apple.mail"] == nil)
    }

    private func seed(model: AppModel, bundleID: String, workflows: [DictationWorkflow]) {
        let data = DictationWorkflowMap.encode([bundleID: workflows])
        model.dictationPerAppOverridesJSON = String(decoding: data, as: UTF8.self)
    }

    @Test("addDictationURLRule preserves existing non-empty entries for the bundle")
    func addURLRulePreservesExisting() {
        let model = makeModel()
        seed(model: model, bundleID: "com.apple.mail", workflows: [
            DictationWorkflow(promptID: "keep"),
        ])

        model.addDictationURLRule(for: "com.apple.mail", pattern: "gmail.com")

        #expect(model.defaultDictationWorkflow(for: "com.apple.mail").promptID == "keep")
    }

    @Test("addDictationURLRule persists a visible rule with the given pattern")
    func addURLRulePersistsPattern() {
        let model = makeModel()

        model.addDictationURLRule(for: "com.apple.mail", pattern: "  gmail.com  ")

        let rules = model.urlDictationRules(for: "com.apple.mail")
        #expect(rules.count == 1)
        #expect(rules.first?.urlPattern == "gmail.com")
    }

    @Test("addDictationURLRule ignores an empty pattern")
    func addURLRuleRejectsEmptyPattern() {
        let model = makeModel()

        model.addDictationURLRule(for: "com.apple.mail", pattern: "   ")

        #expect(model.dictationWorkflows()["com.apple.mail"] == nil)
    }

    @Test("registerDictationOverrideApp lists the app and survives a storage round trip")
    func registerOverrideAppSurvivesRoundTrip() {
        let model = makeModel()

        model.registerDictationOverrideApp("com.example.editor")

        #expect(model.customDictationOverrideApps().contains { $0.bundleID == "com.example.editor" })
        let reencoded = DictationWorkflowMap.decode(legacy: DictationWorkflowMap.encode(model.dictationWorkflows()))
        #expect(reencoded["com.example.editor"]?.isEmpty == false)
    }

    @Test("registerDictationOverrideApp keeps an existing override untouched")
    func registerOverrideAppKeepsExisting() {
        let model = makeModel()
        model.setDictationOverridePromptID("keep", for: "com.example.editor")

        model.registerDictationOverrideApp("com.example.editor")

        #expect(model.defaultDictationWorkflow(for: "com.example.editor").promptID == "keep")
    }

    @Test("updateDictationURLRule mutates only the matching URL-rule index")
    func updateURLRule() {
        let model = makeModel()
        seed(model: model, bundleID: "com.apple.mail", workflows: [
            DictationWorkflow(promptID: "default"),
            DictationWorkflow(urlPattern: "old.com"),
        ])

        model.updateDictationURLRule(for: "com.apple.mail", at: 0) { $0.urlPattern = "github.com" }

        let rules = model.urlDictationRules(for: "com.apple.mail")
        #expect(rules.count == 1)
        #expect(rules.first?.urlPattern == "github.com")
        #expect(model.defaultDictationWorkflow(for: "com.apple.mail").promptID == "default")
    }

    @Test("removeDictationURLRule deletes the rule at the requested visible index")
    func removeURLRule() {
        let model = makeModel()
        seed(model: model, bundleID: "com.apple.mail", workflows: [
            DictationWorkflow(urlPattern: "github.com"),
            DictationWorkflow(urlPattern: "linear.app"),
        ])

        model.removeDictationURLRule(for: "com.apple.mail", at: 0)

        let rules = model.urlDictationRules(for: "com.apple.mail")
        #expect(rules.count == 1)
        #expect(rules.first?.urlPattern == "linear.app")
    }

    @Test("customDictationOverrideApps hides the built-in seed list")
    func customAppsHideSeeds() {
        let model = makeModel()
        let seedID = AppModel.dictationOverrideApps.first!.bundleID
        model.setDictationOverridePromptID("p1", for: seedID)
        model.setDictationOverridePromptID("p2", for: "com.example.custom")

        let custom = model.customDictationOverrideApps().map(\.bundleID)

        #expect(custom.contains(seedID) == false)
        #expect(custom.contains("com.example.custom"))
    }

    @Test("defaultDictationWorkflow returns the entry without a URL pattern")
    func defaultWorkflowSkipsURLRules() {
        let model = makeModel()
        seed(model: model, bundleID: "com.apple.mail", workflows: [
            DictationWorkflow(promptID: "default-prompt"),
            DictationWorkflow(urlPattern: "github.com"),
        ])

        let workflow = model.defaultDictationWorkflow(for: "com.apple.mail")

        #expect(workflow.promptID == "default-prompt")
        #expect(workflow.urlPattern == nil)
    }

    @Test("editing correction rules refreshes a running dictation processor")
    func correctionRulesRefreshRunningProcessor() async {
        let model = makeModel()
        model.startDictation()
        #expect(model.dictationController.isRunning)

        model.correctionRules = [CorrectionRule(from: "q three", to: "Q3")]

        let processor = model.dictationController.configuration?.postProcessor
        let out = await processor?.process("q three results")
        #expect(out == "Q3 results")

        model.stopDictation()
    }

    @Test("toggling self-correction strip refreshes a running dictation processor")
    func selfCorrectionStripRefreshesRunningProcessor() async {
        let model = makeModel()
        model.startDictation()
        #expect(model.dictationController.isRunning)

        model.dictationStripSelfCorrections = true

        let processor = model.dictationController.configuration?.postProcessor
        let out = await processor?.process("scratch that, hello world")
        #expect(out == "hello world", "the strip proves the refresh; Voice mode no longer rewrites case")

        model.stopDictation()
    }

    @Test("toggling dictation context sources refreshes a running dictation processor")
    func contextSourcesRefreshRunningProcessor() {
        let model = makeModel()
        model.startDictation()
        #expect(model.dictationController.isRunning)

        // Built with every context source off → no provider, all-disabled config.
        let initial = model.dictationController.configuration?.postProcessor as? PromptDictationProcessor
        #expect(initial?.contextConfig.isAllDisabled == true)
        #expect(initial?.contextProvider == nil)

        model.dictationContextSelection = true
        let afterSelection = model.dictationController.configuration?.postProcessor as? PromptDictationProcessor
        #expect(afterSelection?.contextConfig.selectionEnabled == true)
        #expect(afterSelection?.contextProvider != nil)

        model.dictationContextClipboard = true
        let afterClipboard = model.dictationController.configuration?.postProcessor as? PromptDictationProcessor
        #expect(afterClipboard?.contextConfig.clipboardEnabled == true)

        model.dictationContextScreen = true
        let afterScreen = model.dictationController.configuration?.postProcessor as? PromptDictationProcessor
        #expect(afterScreen?.contextConfig.screenEnabled == true)

        model.stopDictation()
    }

    @Test("changing the dictation keycode rebinds a running session to the new key")
    func keyCodeChangeRebindsRunningSession() {
        let model = makeModel()
        model.dictationEnabled = true
        #expect(model.dictationController.isRunning)
        #expect(model.dictationController.configuration?.hotkeyKeyCode == 96)  // default F5

        model.dictationKeyCode = 97  // F6

        #expect(model.dictationController.isRunning)
        #expect(model.dictationController.configuration?.hotkeyKeyCode == 97)

        model.stopDictation()
    }

    @Test("changing the dictation modifiers rebinds a running session with the new mask")
    func keyModifiersChangeRebindRunningSession() {
        let model = makeModel()
        model.dictationEnabled = true
        #expect(model.dictationController.isRunning)
        #expect(model.dictationController.configuration?.hotkeyModifiers == [])

        model.dictationKeyModifiers = Int(NSEvent.ModifierFlags.command.rawValue)

        #expect(model.dictationController.configuration?.hotkeyModifiers == .command)

        model.stopDictation()
    }

    @Test("changing the paste delay re-applies to a running session")
    func pasteDelayChangeReappliesToRunningSession() async {
        let model = makeModel()
        model.dictationEnabled = true
        #expect(model.dictationController.isRunning)
        #expect(model.dictationController.configuration?.pasteDelayMs == 0)

        model.dictationPasteDelayMs = 250
        // The restart is debounced so per-keystroke edits don't thrash the coordinator; flush it.
        await model.pendingDictationRestart?.value

        #expect(model.dictationController.isRunning)
        #expect(model.dictationController.configuration?.pasteDelayMs == 250)

        model.stopDictation()
    }

    @Test("startDictation threads the custom vocabulary prompt into the configuration")
    func startDictationThreadsInitialPrompt() {
        let model = makeModel()
        model.initialPrompt = "Parola, WhisperKit, Valloncini"
        model.startDictation()
        #expect(model.dictationController.configuration?.initialPrompt == "Parola, WhisperKit, Valloncini")
        model.stopDictation()
    }

    @Test("an empty custom vocabulary reaches the recorder as nil")
    func emptyInitialPromptBecomesNil() {
        let model = makeModel()
        model.initialPrompt = ""
        model.startDictation()
        #expect(model.dictationController.configuration?.initialPrompt == nil)
        model.stopDictation()
    }

    @Test("the recorder builds transcription options with the initial prompt")
    func recorderOptionsCarryInitialPrompt() async {
        let recorder = MicDictationRecorder(
            model: "openai_whisper-tiny",
            language: "en",
            initialPrompt: "Parola, WhisperKit"
        )
        let options = await recorder.transcriptionOptions()
        #expect(options.initialPrompt == "Parola, WhisperKit")
        #expect(options.model == "openai_whisper-tiny")
        #expect(options.language == "en")
    }

    @Test("startDictation threads the preferred input device into the configuration")
    func startDictationThreadsInputDevice() {
        let model = makeModel()
        model.inputDeviceUID = "usb-mic-uid"
        model.startDictation()
        #expect(model.dictationController.configuration?.deviceUID == "usb-mic-uid")
        model.stopDictation()
    }

    @Test("startDictation wires the shared media session into the configuration")
    func startDictationWiresMediaSession() async {
        let model = makeModel()
        model.autoMuteWhileRecording = true
        model.autoPauseMediaWhileRecording = false
        model.startDictation()

        #expect(model.dictationController.configuration?.mediaSession === model.mediaSession)
        let config = await model.dictationController.configuration?.mediaConfigProvider?()
        #expect(config == MediaSessionConfig(muteSystemAudio: true, pausePlayback: false))

        model.autoMuteWhileRecording = false
        model.autoPauseMediaWhileRecording = true
        let updated = await model.dictationController.configuration?.mediaConfigProvider?()
        #expect(updated == MediaSessionConfig(muteSystemAudio: false, pausePlayback: true))

        model.stopDictation()
    }

    @Test("prewarm candidate is the model only for installed streaming WhisperKit variants")
    func prewarmCandidateGates() {
        let whisper = "openai_whisper-large-v3_turbo"
        let parakeet = "nvidia_parakeet-tdt-0.6b-v2"

        #expect(AppModel.streamingPrewarmCandidate(model: whisper, useStreaming: true, isInstalled: { _ in true }) == whisper)
        #expect(AppModel.streamingPrewarmCandidate(model: whisper, useStreaming: false, isInstalled: { _ in true }) == nil)
        #expect(AppModel.streamingPrewarmCandidate(model: whisper, useStreaming: true, isInstalled: { _ in false }) == nil)
        #expect(AppModel.streamingPrewarmCandidate(model: parakeet, useStreaming: true, isInstalled: { _ in true }) == nil)
        #expect(
            AppModel.streamingPrewarmCandidate(model: "legacy-dir", useStreaming: true, isInstalled: { _ in true }) == "legacy-dir",
            "installed ids outside the catalog are legacy WhisperKit dirs and stream"
        )
        #expect(AppModel.streamingPrewarmCandidate(model: "legacy-dir", useStreaming: true, isInstalled: { _ in false }) == nil)
    }

    @Test("model download progress updates once per whole percent and clears at completion")
    func downloadProgressThrottlesAndClears() {
        let model = makeModel()
        model.dictationController.recorderFactory = { _ in IntentStubRecorder() }
        model.dictationEnabled = true
        let controller = model.dictationController

        controller.noteModelDownloadProgress(0.421)
        #expect(controller.modelDownloadProgress == 0.421)

        controller.noteModelDownloadProgress(0.429)
        #expect(controller.modelDownloadProgress == 0.421)

        controller.noteModelDownloadProgress(0.43)
        #expect(controller.modelDownloadProgress == 0.43)

        controller.noteModelDownloadProgress(1.0)
        #expect(controller.modelDownloadProgress == nil)
        model.abortDictation()
    }

    @Test("stopping dictation clears a stale download progress")
    func stopClearsDownloadProgress() {
        let model = makeModel()
        model.dictationController.recorderFactory = { _ in IntentStubRecorder() }
        model.dictationEnabled = true
        let controller = model.dictationController
        controller.noteModelDownloadProgress(0.5)
        #expect(controller.modelDownloadProgress == 0.5)

        controller.stop()

        #expect(controller.modelDownloadProgress == nil)
    }

    @Test("rewriting the same hotkey values neither persists nor restarts")
    func sameHotkeyWriteIsIgnored() {
        let defaults = makeIsolatedDefaults()
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("dictation-hotkey"))
        defaults.removeObject(forKey: "dictationKeyCode")
        defaults.removeObject(forKey: "dictationKeyModifiers")

        model.dictationKeyCode = model.dictationKeyCode
        model.dictationKeyModifiers = model.dictationKeyModifiers

        #expect(defaults.object(forKey: "dictationKeyCode") == nil)
        #expect(defaults.object(forKey: "dictationKeyModifiers") == nil)

        model.dictationKeyCode = 105
        #expect(defaults.integer(forKey: "dictationKeyCode") == 105)
    }

    @Test("startDictationFromIntent restarts a stopped controller when already enabled")
    func intentStartsStoppedController() {
        let model = makeModel()
        model.dictationController.recorderFactory = { _ in IntentStubRecorder() }
        model.dictationEnabled = true
        #expect(model.dictationController.isRunning)
        model.stopDictation()
        #expect(model.dictationController.isRunning == false)

        model.startDictationFromIntent()

        #expect(model.dictationController.isRunning)
        model.abortDictation()
    }
}

private struct IntentStubRecorder: DictationRecorder {
    func start() async throws {}
    func stopAndTranscribe() async throws -> String { "" }
}
