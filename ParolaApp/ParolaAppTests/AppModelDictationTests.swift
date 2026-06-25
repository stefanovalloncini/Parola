import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaDictation

@MainActor
@Suite("AppModel dictation")
struct AppModelDictationTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID())")!
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
        model.addDictationURLRule(for: "com.apple.mail")

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

        model.addDictationURLRule(for: "com.apple.mail")

        #expect(model.defaultDictationWorkflow(for: "com.apple.mail").promptID == "keep")
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
        #expect(out == "Hello world")

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
}
