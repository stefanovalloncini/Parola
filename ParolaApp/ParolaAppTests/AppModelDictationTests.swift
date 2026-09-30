import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaDictation
import ParolaTestSupport

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

        let parakeetV3Japanese = AppModel.dictationModelWarnings(
            model: "nvidia_parakeet-tdt-0.6b-v3", useStreaming: true, language: "ja", isInstalled: true)
        #expect(parakeetV3Japanese.contains { $0.contains("Japanese") })
        #expect(!parakeetV3Japanese.contains { $0.contains("English-only") })

        let parakeetV3Italian = AppModel.dictationModelWarnings(
            model: "nvidia_parakeet-tdt-0.6b-v3", useStreaming: true, language: "it", isInstalled: true)
        #expect(!parakeetV3Italian.contains { $0.contains("support") })
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

        model.correctionRules = [CorrectionRule(from: "q three", to: "Q")]
        model.correctionRules = [CorrectionRule(from: "q three", to: "Q3")]
        // The rebuild waits for the pane's typing to settle; flush it.
        await model.pendingDictationProcessorRebuild?.value

        let processor = model.dictationController.configuration?.postProcessor
        let out = await processor?.process("q three results")
        #expect(out == "Q3 results")

        model.stopDictation()
    }

    @Test("editing snippets refreshes a running dictation processor once the typing settles")
    func snippetEditsRefreshRunningProcessor() async {
        let model = makeModel()
        model.startDictation()
        #expect(model.dictationController.isRunning)

        model.snippets = [Snippet(trigger: "o", replacement: "?")]
        let pending = model.pendingDictationProcessorRebuild
        model.snippets = [Snippet(trigger: "omw", replacement: "on my way")]
        #expect(pending?.isCancelled == true)
        await model.pendingDictationProcessorRebuild?.value

        let out = await model.dictationController.configuration?.postProcessor.process("omw home")
        #expect(out == "on my way home")

        model.stopDictation()
    }

    @Test("rule edits with dictation off schedule nothing")
    func ruleEditsWithDictationOffScheduleNothing() {
        let model = makeModel()
        model.correctionRules = [CorrectionRule(from: "teh", to: "the")]
        #expect(model.pendingDictationProcessorRebuild == nil)
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

    @Test("discarding a streamed dictation cancels the take instead of decoding its tail")
    func discardCancelsTheStream() async throws {
        let spy = EndingSpy()
        let recorder = MicDictationRecorder(
            model: "openai_whisper-tiny",
            language: "en",
            makeStreamingSession: { spy }
        )
        try await recorder.start()

        await recorder.stopAndDiscard()

        #expect(await spy.ends == ["cancel"])
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

    @Test("model download progress shows each reading and clears at completion")
    func downloadProgressShowsAndClears() {
        let model = makeModel()
        model.dictationController.recorderFactory = { _ in IntentStubRecorder() }
        model.dictationEnabled = true
        let controller = model.dictationController

        controller.noteModelDownloadProgress(0.421)
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

    @Test("without the hotkey side effect, turning dictation on arms it on a monitor that hears no keys")
    func dictationWithoutTheHotkeyListensToNoKeys() {
        let model = makeModel()
        model.dictationController.recorderFactory = { _ in IntentStubRecorder() }

        model.dictationEnabled = true
        #expect(model.dictationController.isRunning)
        #expect(model.dictationController.configuration?.listensForHotkey == false)

        model.dictationKeyCode = 105
        #expect(model.dictationController.configuration?.listensForHotkey == false)
        model.abortDictation()
    }

    @Test("only a configuration allowed to listen gets the global key monitor")
    func hotkeyMonitorFollowsTheGate() {
        var configuration = DictationController.Configuration(
            modelName: "openai_whisper-tiny",
            language: nil,
            deviceUID: nil,
            streamingEnabled: false,
            hotkeyKeyCode: 96,
            mode: .pushToTalk,
            workflows: [:],
            postProcessor: IdentityPostProcessor()
        )
        #expect(DictationController.hotkeyMonitor(for: configuration) is SilentHotkeyMonitor)

        configuration.listensForHotkey = true
        #expect(DictationController.hotkeyMonitor(for: configuration) is GlobalHotkeyMonitor)
    }

    @Test("without the mic hotkey side effect, binding installs no key monitor")
    func micHotkeyStaysOffWithoutTheSideEffect() async {
        let model = makeModel()
        model.micHotkeyEnabled = true
        let controller = MicHotkeyController()
        controller.monitorFactory = { _, _ in SilentHotkeyMonitor() }

        controller.bind(model)
        await Task.yield()

        #expect(controller.monitor == nil)
    }

    @Test("stopping dictation resets the state the menu bar and the bridge read")
    func stopResetsTheModelState() {
        let model = makeModel()
        model.dictationController.recorderFactory = { _ in IntentStubRecorder() }
        model.dictationEnabled = true
        model.dictationState = .transcribing

        model.stopDictation()

        #expect(model.dictationState == .idle)
        #expect(!model.dictationController.isRunning)
    }

    @Test("a settings reload that turns dictation off stops it, in test mode too")
    func reloadStopsDisabledDictation() {
        let defaults = makeIsolatedDefaults()
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("dictation-reload"))
        model.dictationPerAppOverridesJSON = "{}"
        model.dictationController.recorderFactory = { _ in IntentStubRecorder() }
        model.dictationEnabled = true
        #expect(model.dictationController.isRunning)

        defaults.set(false, forKey: "dictationEnabled")
        model.reloadSettings()

        #expect(!model.dictationEnabled)
        #expect(!model.dictationController.isRunning)
    }

    @Test("a bridge stop while the final transcription hangs gives up after the grace and re-arms a fresh recorder")
    func stopWhileTranscribingGivesUp() async {
        let model = makeModel()
        let recorders = RecorderTally()
        model.dictationController.recorderFactory = { _ in recorders.make() }
        model.dictationController.transcriptionStopGrace = .milliseconds(50)
        model.dictationEnabled = true
        model.dictationController.simulatePress()
        let dictationStateWait = await waitUntil { model.dictationState == .listening }
        #expect(dictationStateWait)

        model.stopDictationFromIntent()
        let dictationStateWait2 = await waitUntil { model.dictationState == .transcribing }
        #expect(dictationStateWait2)

        model.stopDictationFromBridge()
        let countWait = await waitUntil { recorders.made.count == 2 }
        #expect(countWait)
        #expect(model.dictationState == .idle)
        #expect(model.dictationController.state == .idle)
        #expect(model.dictationController.isRunning)

        for recorder in recorders.made { await recorder.release() }
        model.abortDictation()
    }

    @Test("a stop from an intent or a link never gives up a final already under way")
    func intentStopWaitsForTheFinal() async throws {
        let model = makeModel()
        let recorders = RecorderTally()
        model.dictationController.recorderFactory = { _ in recorders.make() }
        model.dictationController.transcriptionStopGrace = .milliseconds(50)
        model.dictationEnabled = true
        model.dictationController.simulatePress()
        let dictationStateWait = await waitUntil { model.dictationState == .listening }
        #expect(dictationStateWait)
        model.stopDictationFromIntent()
        let dictationStateWait2 = await waitUntil { model.dictationState == .transcribing }
        #expect(dictationStateWait2)

        model.stopDictationFromIntent()
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.dictationState == .transcribing)
        #expect(recorders.made.count == 1)

        for recorder in recorders.made { await recorder.release() }
        let dictationStateWait3 = await waitUntil { model.dictationState == .idle }
        #expect(dictationStateWait3)
        model.abortDictation()
    }

    @Test("Cancel drops the final at once, without the stop's grace, and re-arms a fresh recorder")
    func cancelDropsTheFinalAtOnce() async {
        let model = makeModel()
        let recorders = RecorderTally()
        model.dictationController.recorderFactory = { _ in recorders.make() }
        model.dictationController.transcriptionStopGrace = .seconds(60)
        model.dictationEnabled = true
        model.dictationController.simulatePress()
        let dictationStateWait = await waitUntil { model.dictationState == .listening }
        #expect(dictationStateWait)
        model.stopDictationFromIntent()
        let dictationStateWait2 = await waitUntil { model.dictationState == .transcribing }
        #expect(dictationStateWait2)

        model.dictationController.cancelTranscription()

        let countWait = await waitUntil(timeoutMs: 2000) { recorders.made.count == 2 }
        #expect(countWait)
        #expect(model.dictationState == .idle)
        for recorder in recorders.made { await recorder.release() }
        model.abortDictation()
    }

    /// Dictation on, a final held in its recorder, and every paste recorded instead of posted.
    private func modelHoldingAFinal() async -> (AppModel, RecorderTally, CapturedInsertionStore) {
        let model = makeModel()
        let recorders = RecorderTally(text: "spoken words")
        let pasted = CapturedInsertionStore()
        model.dictationController.recorderFactory = { _ in recorders.make() }
        model.dictationController.inserterFactory = { CapturingTextInserter(store: pasted) }
        model.dictationEnabled = true
        model.dictationController.simulatePress()
        let dictationStateWait = await waitUntil { model.dictationState == .listening }
        #expect(dictationStateWait)
        model.stopDictationFromIntent()
        let dictationStateWait2 = await waitUntil { model.dictationState == .transcribing }
        #expect(dictationStateWait2)
        return (model, recorders, pasted)
    }

    @Test("turning dictation off mid-final drops it: nothing is pasted")
    func turningOffDropsThePendingFinal() async throws {
        let (model, recorders, pasted) = await modelHoldingAFinal()

        model.dictationEnabled = false
        #expect(model.dictationState == .idle)
        #expect(!model.dictationController.isRunning)

        for recorder in recorders.made { await recorder.release() }
        let recordersWait = await waitUntil { await recorders.made.first?.returned == true }
        #expect(recordersWait)
        try await Task.sleep(for: .milliseconds(150))
        #expect(pasted.all().isEmpty)
    }

    @Test("a restart mid-final still pastes the last utterance")
    func restartKeepsThePendingFinal() async throws {
        let (model, recorders, pasted) = await modelHoldingAFinal()

        model.restartDictation()
        #expect(model.dictationController.isRunning)

        for recorder in recorders.made { await recorder.release() }
        let allWait = await waitUntil { pasted.all() == ["spoken words"] }
        #expect(allWait)
        model.abortDictation()
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

private actor EndingSpy: StreamingTranscriber {
    private(set) var ends: [String] = []
    private var continuation: AsyncStream<StreamingEvent>.Continuation?

    func start(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)?,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> AsyncStream<StreamingEvent> {
        let (stream, continuation) = AsyncStream<StreamingEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() async {
        ends.append("stop")
        continuation?.finish()
    }

    func cancel() async {
        ends.append("cancel")
        continuation?.finish()
    }

    func currentModel() async -> String? { "openai_whisper-tiny" }
}

private struct IdentityPostProcessor: TextPostProcessor {
    func process(_ text: String) async -> String { text }
}

private actor StuckRecorder: DictationRecorder {
    private let text: String
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var returned = false

    init(text: String = "") { self.text = text }

    func start() async throws {}

    func stopAndTranscribe() async throws -> String {
        await withCheckedContinuation { gate = $0 }
        returned = true
        return text
    }

    func stopAndDiscard() async {}

    func release() {
        gate?.resume()
        gate = nil
    }
}

@MainActor
private final class RecorderTally {
    private let text: String
    private(set) var made: [StuckRecorder] = []

    init(text: String = "") { self.text = text }

    func make() -> StuckRecorder {
        let recorder = StuckRecorder(text: text)
        made.append(recorder)
        return recorder
    }
}
