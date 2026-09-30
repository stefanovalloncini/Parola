import Combine
import Foundation
import SwiftUI
import AppKit
import ParolaCore
import ParolaDictation

extension AppModel {

    func dictationWorkflows() -> [String: [DictationWorkflow]] {
        let json = dictationPerAppOverridesJSON
        if let cached = cachedDictationWorkflows, cached.json == json {
            return cached.map
        }
        let map: [String: [DictationWorkflow]]
        if let data = json.data(using: .utf8) {
            map = DictationWorkflowMap.decode(legacy: data)
        } else {
            map = [:]
        }
        cachedDictationWorkflows = (json, map)
        return map
    }

    func defaultDictationWorkflow(for bundleID: String) -> DictationWorkflow {
        DictationWorkflowMap.defaultWorkflow(in: dictationWorkflows(), for: bundleID) ?? DictationWorkflow()
    }

    func urlDictationRules(for bundleID: String) -> [DictationWorkflow] {
        DictationWorkflowMap.urlRules(in: dictationWorkflows(), for: bundleID)
    }

    private func writeDictationWorkflows(_ map: [String: [DictationWorkflow]]) {
        let data = DictationWorkflowMap.encode(map)
        dictationPerAppOverridesJSON = String(decoding: data, as: UTF8.self)
    }

    func setDefaultDictationWorkflow(_ workflow: DictationWorkflow, for bundleID: String) {
        var map = dictationWorkflows()
        var entries = map[bundleID] ?? []
        entries.removeAll { ($0.urlPattern ?? "").isEmpty }
        var sanitized = workflow
        sanitized.urlPattern = nil
        if !sanitized.isEmpty {
            entries.insert(sanitized, at: 0)
        }
        if entries.isEmpty {
            map.removeValue(forKey: bundleID)
        } else {
            map[bundleID] = entries
        }
        writeDictationWorkflows(map)
    }

    func dictationOverridePromptID(for bundleID: String) -> String {
        defaultDictationWorkflow(for: bundleID).promptID ?? ""
    }

    func setDictationOverridePromptID(_ promptID: String, for bundleID: String) {
        var workflow = defaultDictationWorkflow(for: bundleID)
        workflow.promptID = promptID.isEmpty ? nil : promptID
        setDefaultDictationWorkflow(workflow, for: bundleID)
    }

    func dictationOverrideLanguage(for bundleID: String) -> String {
        defaultDictationWorkflow(for: bundleID).language ?? ""
    }

    func setDictationOverrideLanguage(_ language: String, for bundleID: String) {
        var workflow = defaultDictationWorkflow(for: bundleID)
        workflow.language = language.isEmpty ? nil : language
        setDefaultDictationWorkflow(workflow, for: bundleID)
    }

    func dictationOverrideInsertion(for bundleID: String) -> DictationInsertionMode {
        defaultDictationWorkflow(for: bundleID).insertion ?? .paste
    }

    func setDictationOverrideInsertion(_ mode: DictationInsertionMode, for bundleID: String) {
        var workflow = defaultDictationWorkflow(for: bundleID)
        workflow.insertion = (mode == .paste) ? nil : mode
        // A custom-added app lives in storage only through its explicit .paste pin
        // (registerDictationOverrideApp); an all-nil workflow would drop its row.
        if workflow.isEmpty, !AppModel.dictationOverrideApps.contains(where: { $0.bundleID == bundleID }) {
            workflow.insertion = .paste
        }
        setDefaultDictationWorkflow(workflow, for: bundleID)
    }

    /// Display name of the dictation cleanup mode for a stored prompt-ID string —
    /// shared by the Dictation pane preview and the live HUD so they can't drift.
    static func dictationCleanupModeName(for id: String) -> String? {
        if id.isEmpty {
            return DictationModePreset.builtIns.first { $0.promptID == nil }?.name
        }
        guard let uuid = UUID(uuidString: id) else { return nil }
        if let preset = DictationModePreset.builtIns.first(where: { $0.promptID == uuid }) {
            return preset.name
        }
        return Prompt.builtIns.first(where: { $0.id == uuid })?.name
    }

    func removeDictationOverride(for bundleID: String) {
        var map = dictationWorkflows()
        map.removeValue(forKey: bundleID)
        writeDictationWorkflows(map)
    }

    func addDictationURLRule(for bundleID: String, pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var map = dictationWorkflows()
        var entries = map[bundleID] ?? []
        entries.append(DictationWorkflow(urlPattern: trimmed))
        map[bundleID] = entries
        writeDictationWorkflows(map)
    }

    func removeDictationURLRule(for bundleID: String, at index: Int) {
        var map = dictationWorkflows()
        guard var entries = map[bundleID] else { return }
        let rules = entries.enumerated().filter { !($0.element.urlPattern ?? "").isEmpty }
        guard index >= 0, index < rules.count else { return }
        let absoluteIndex = rules[index].offset
        entries.remove(at: absoluteIndex)
        if entries.isEmpty {
            map.removeValue(forKey: bundleID)
        } else {
            map[bundleID] = entries
        }
        writeDictationWorkflows(map)
    }

    func updateDictationURLRule(
        for bundleID: String,
        at index: Int,
        transform: (inout DictationWorkflow) -> Void
    ) {
        var map = dictationWorkflows()
        guard var entries = map[bundleID] else { return }
        let rules = entries.enumerated().filter { !($0.element.urlPattern ?? "").isEmpty }
        guard index >= 0, index < rules.count else { return }
        let absoluteIndex = rules[index].offset
        var workflow = entries[absoluteIndex]
        transform(&workflow)
        if workflow.isEmpty {
            entries.remove(at: absoluteIndex)
        } else {
            entries[absoluteIndex] = workflow
        }
        if entries.isEmpty {
            map.removeValue(forKey: bundleID)
        } else {
            map[bundleID] = entries
        }
        writeDictationWorkflows(map)
    }

    func presentAddDictationAppPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Pick an app to give it a custom dictation workflow."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        registerDictationOverrideApp(bundleID)
    }

    // An all-defaults workflow can't round-trip storage (cleaned() strips empty entries),
    // so a fresh app is pinned with an explicit .paste insertion — same behavior as the default.
    func registerDictationOverrideApp(_ bundleID: String) {
        guard defaultDictationWorkflow(for: bundleID).isEmpty else { return }
        setDefaultDictationWorkflow(DictationWorkflow(insertion: .paste), for: bundleID)
    }

    func customDictationOverrideApps() -> [(bundleID: String, name: String)] {
        let seedIDs = Set(AppModel.dictationOverrideApps.map(\.bundleID))
        let map = dictationWorkflows()
        return map.keys.compactMap { bundleID -> (String, String)? in
            guard !seedIDs.contains(bundleID) else { return nil }
            let name = displayName(forBundleID: bundleID)
            return (bundleID, name)
        }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    private func displayName(forBundleID bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let info = Bundle(url: url)?.infoDictionary
            if let name = info?["CFBundleDisplayName"] as? String, !name.isEmpty { return name }
            if let name = info?["CFBundleName"] as? String, !name.isEmpty { return name }
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }

    func wireDictationController() {
        dictationController.appModel = self
        dictationController.indicatorStyle = dictationIndicatorStyle
        dictationPermissions.onAccessibilityGranted = { [weak self] in
            guard let self, self.dictationEnabled, self.dictationController.isRunning else { return }
            self.restartDictation()
        }
    }

    func restartDictation() {
        guard dictationEnabled, dictationController.isRunning else { return }
        stopDictation()
        startDictation()
    }

    /// Debounced restart for the two settings bound to a live control — the custom-vocabulary
    /// field and the paste-delay slider. Restarting the hotkey coordinator per keystroke/tick
    /// would thrash it and spawn a prewarm task each time; coalesce to one restart once editing settles.
    func scheduleDictationRestart() {
        pendingDictationRestart?.cancel()
        guard dictationEnabled, dictationController.isRunning else {
            pendingDictationRestart = nil
            return
        }
        let clock = clock
        pendingDictationRestart = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400), clock: clock)
            guard !Task.isCancelled else { return }
            self?.restartDictation()
        }
    }

    func applyDictationEnabledChange() {
        guard features.isEnabled(.dictation) else { return }
        if dictationEnabled {
            dictationPermissions.refresh()
            // Gated to real launches, like prewarmDictationModel(): an ungated prompt is a modal system dialog that hangs xcodebuild test.
            if !dictationPermissions.accessibilityGranted, activeSideEffects.contains(.dictationHotkey) {
                dictationPermissions.promptForAccessibility()
                dictationPermissions.beginWatchingForGrant()
            }
            startDictation()
        } else {
            dictationPermissions.endWatchingForGrant()
            turnOffDictation()
        }
    }

    /// Unlike a restart's stop, this drops a final still on its way: nothing is pasted once dictation is off.
    func turnOffDictation() {
        pendingDictationRestart?.cancel()
        pendingDictationRestart = nil
        dictationController.discardAndStop()
    }

    func startDictation() {
        guard features.isEnabled(.dictation) else { return }
        guard !dictationController.isRunning else { return }
        let configuration = DictationController.Configuration(
            modelName: selectedModel,
            language: selectedLanguage,
            initialPrompt: initialPrompt.isEmpty ? nil : initialPrompt,
            deviceUID: preferredInputDeviceUID,
            streamingEnabled: useStreaming,
            hotkeyKeyCode: dictationKeyCode,
            hotkeyModifiers: dictationModifierFlags,
            listensForHotkey: activeSideEffects.contains(.dictationHotkey),
            mode: dictationMode,
            workflows: dictationWorkflows(),
            postProcessor: currentDictationProcessor(),
            pasteDelayMs: max(0, min(2000, dictationPasteDelayMs)),
            mediaSession: mediaSession,
            mediaConfigProvider: { [weak self] in
                await MainActor.run { self?.mediaSessionConfig(allowMute: true) ?? .none }
            }
        )
        dictationController.indicatorStyle = dictationIndicatorStyle
        dictationController.start(configuration: configuration)
        prewarmDictationModel()
    }

    /// Warms the streaming model as soon as the dictation hotkey is armed, so the first press
    /// doesn't lose speech to the model load. Gated to real launches: test runs wire no hotkey.
    func prewarmDictationModel() {
        guard activeSideEffects.contains(.dictationHotkey) else { return }
        guard let name = AppModel.streamingPrewarmCandidate(
            model: selectedModel,
            useStreaming: useStreaming,
            isInstalled: { ModelStore.shared.isInstalled($0) }
        ) else { return }
        Task.detached {
            await StreamingTranscriberFactory.prewarm(modelName: name)
        }
    }

    /// Non-blocking advisories for the Dictation pane: dictation follows the selected
    /// model, and some choices degrade it (English-only, no streaming, not installed).
    nonisolated static func dictationModelWarnings(
        model: String,
        useStreaming: Bool,
        language: String?,
        isInstalled: Bool
    ) -> [String] {
        var warnings: [String] = []
        let label = modelLabel(model)
        let variant = ModelCatalog.variant(id: model)
        if let language,
           let caps = ModelCatalog.staticCapabilities(forID: model),
           !caps.supportedLanguages.allows(language) {
            if caps.supportedLanguages.isEnglishOnly {
                warnings.append(String(localized: "\(label) is English-only. Dictation in other languages won't work."))
            } else {
                let languageName = LanguageDisplay.name(for: language) ?? language
                warnings.append(String(localized: "\(label) doesn't support \(languageName). Dictation in that language won't work."))
            }
        }
        if !ModelCatalog.canStream(id: model) {
            warnings.append(String(localized: "\(label) doesn't stream: no live preview, and the text arrives only after processing."))
        } else if !useStreaming {
            warnings.append(String(localized: "Streaming is off in General settings, so dictation shows no live preview."))
        }
        if let variant, !isInstalled {
            warnings.append(String(localized: "\(label) isn't installed. The first dictation press downloads \(AppFormat.byteSize(variant.sizeBytes))."))
        }
        return warnings
    }

    var dictationModelWarnings: [String] {
        let installed = availableModels.first(where: { $0.name == selectedModel })?.isInstalled ?? false
        return AppModel.dictationModelWarnings(
            model: selectedModel,
            useStreaming: useStreaming,
            language: selectedLanguage,
            isInstalled: installed
        )
    }

    static func streamingPrewarmCandidate(
        model: String,
        useStreaming: Bool,
        isInstalled: (String) -> Bool
    ) -> String? {
        guard useStreaming, ModelCatalog.canStream(id: model), isInstalled(model) else { return nil }
        return model
    }

    func applyDictationModeChange() {
        dictationController.setMode(dictationMode)
    }


    private func currentDictationCleanupPrompt() -> Prompt? {
        guard let uuid = UUID(uuidString: dictationCleanupPromptID) else { return nil }
        return Prompt.builtIns.first { $0.id == uuid }
    }

    private func currentDictationOverrides() -> [String: [DictationOverrideEntry]] {
        var out: [String: [DictationOverrideEntry]] = [:]
        for (bundleID, workflows) in dictationWorkflows() {
            let entries: [DictationOverrideEntry] = workflows.compactMap { workflow in
                guard let promptID = workflow.promptID,
                      let uuid = UUID(uuidString: promptID),
                      let prompt = Prompt.builtIns.first(where: { $0.id == uuid }) else {
                    return nil
                }
                return DictationOverrideEntry(prompt: prompt, urlPattern: workflow.urlPattern)
            }
            if !entries.isEmpty { out[bundleID] = entries }
        }
        return out
    }

    private func currentDictationProcessor() -> any TextPostProcessor {
        let contextConfig = DictationContextConfig(
            selectionEnabled: dictationContextSelection,
            clipboardEnabled: dictationContextClipboard,
            screenEnabled: dictationContextScreen
        )
        let contextProvider: DictationContextProvider? = contextConfig.isAllDisabled
            ? nil
            : DictationContextProvider(source: MacContextSource())
        let prompt = PromptDictationProcessor(
            defaultPrompt: currentDictationCleanupPrompt(),
            overrides: currentDictationOverrides(),
            triggerPrompts: cachedDictationTriggerPrompts,
            contextProvider: contextProvider,
            contextConfig: contextConfig,
            language: selectedLanguage,
            cleanupRunner: dictationCleanupRunner()
        )
        var chain: [any TextPostProcessor] = []
        if dictationStripSelfCorrections {
            chain.append(SelfCorrectionCleaner())
        }
        if correctionRules.contains(where: { $0.enabled && !$0.from.isEmpty }) {
            chain.append(CorrectionRuleSet(rules: correctionRules))
        }
        if snippets.contains(where: { $0.enabled }) {
            chain.append(makeSnippetExpander())
        }
        chain.append(prompt)
        // Deferred snippets expand after cleanup so {{CLIPBOARD}}/{{TIME}} read insert-time state.
        if snippets.contains(where: { $0.enabled && $0.expandAtInsert }) {
            chain.append(makeSnippetExpander().deferredOnly())
        }
        return chain.count == 1 ? prompt : CompositePostProcessor(chain)
    }

    func applyDictationCleanupPromptChange() {
        guard dictationController.isRunning else { return }
        dictationController.setPostProcessor(currentDictationProcessor())
    }

    /// The Snippets and Corrections panes write on every keystroke; the chain is rebuilt once the typing settles.
    func scheduleDictationProcessorRebuild() {
        pendingDictationProcessorRebuild?.cancel()
        guard dictationController.isRunning else {
            pendingDictationProcessorRebuild = nil
            return
        }
        let clock = clock
        pendingDictationProcessorRebuild = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400), clock: clock)
            guard !Task.isCancelled else { return }
            self?.applyDictationCleanupPromptChange()
        }
    }

    func refreshDictationTriggerPrompts() async {
        let user = await promptLibrary.userPrompts
        let prompts = (Prompt.builtIns + user).filter { !$0.triggerWords.isEmpty }
        await MainActor.run {
            self.cachedDictationTriggerPrompts = prompts
            self.applyDictationCleanupPromptChange()
        }
    }

    func startDictationFromIntent() {
        guard features.isEnabled(.dictation) else { return }
        if !dictationEnabled {
            dictationEnabled = true
        } else if !dictationController.isRunning {
            startDictation()
        }
        dictationController.simulatePress()
    }

    func stopDictationFromIntent() {
        dictationController.requestStop()
    }

    /// A script must not wait forever on a final that never lands, so the bridge's stop gives one up after the grace.
    func stopDictationFromBridge() {
        dictationController.requestStop(giveUpAfter: dictationController.transcriptionStopGrace)
    }

    func stopDictation() {
        pendingDictationRestart?.cancel()
        pendingDictationRestart = nil
        dictationController.stop()
    }

    func abortDictation() {
        dictationController.abort()
    }

    func applyIndicatorStyleChange() {
        dictationController.indicatorStyle = dictationIndicatorStyle
    }
}
