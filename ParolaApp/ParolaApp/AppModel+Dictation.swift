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
        panel.message = String(localized: "Pick an app to give it a custom dictation workflow.")
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

    func applyDictationModelChange() {
        guard dictationEnabled, dictationController.isRunning else { return }
        prewarmDictationModel()
    }

    func reapplyDictationAfterReload() {
        let running = dictationController.configuration
        guard dictationController.isRunning,
              running?.hotkeyKeyCode == dictationKeyCode,
              running?.hotkeyModifiers == dictationModifierFlags,
              running?.mode == dictationMode
        else {
            stopDictation()
            startDictation()
            return
        }
        applyIndicatorStyleChange()
        modelResidency.dictationArmed()
        applyDictationModelChange()
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

    func dictationModelToRelease() -> String {
        lastDictationModel ?? dictationController.configuration?.pipeline.modelName ?? selectedModel
    }

    /// Unlike a restart's stop, this drops a final still on its way: nothing is pasted once dictation is off.
    func turnOffDictation() {
        let mayBeTranscribing = dictationController.state != .idle
        let configuredModel = dictationModelToRelease()
        dictationController.discardAndStop()
        let residency = modelResidency
        let epoch = residency.warmEpoch
        dictationController.afterTeardown {
            await residency.releaseStreamingModels(ifUnchangedSince: epoch)
            await residency.releaseDictationSession(ifUnchangedSince: epoch, configuredModel: configuredModel, mayBeRunning: mayBeTranscribing)
        }
    }

    func startDictation() {
        guard features.isEnabled(.dictation) else { return }
        guard !dictationController.isRunning else { return }
        let configuration = DictationController.Configuration(
            pipeline: dictationPipelineConfiguration(),
            pipelineProvider: { [weak self] in
                await MainActor.run { self?.pressedPipelineConfiguration() ?? DictationPipelineConfiguration(postProcessor: DictationNoProcessing()) }
            },
            hotkeyKeyCode: dictationKeyCode,
            hotkeyModifiers: dictationModifierFlags,
            listensForHotkey: activeSideEffects.contains(.dictationHotkey),
            mode: dictationMode,
            mediaSession: mediaSession,
            mediaConfigProvider: { [weak self] in
                await MainActor.run { self?.mediaSessionConfig(allowMute: true) ?? .none }
            },
            willListen: { [weak self] in
                await self?.readAloud.yield(to: .dictation)
            }
        )
        dictationController.indicatorStyle = dictationIndicatorStyle
        dictationController.start(configuration: configuration)
        modelResidency.dictationArmed()
        prewarmDictationModel()
    }

    /// Warms the streaming model as soon as the dictation hotkey is armed, so the first press
    /// doesn't lose speech to the model load. Gated to real launches: test runs wire no hotkey.
    func prewarmDictationModel() {
        let residency = modelResidency
        guard let name = AppModel.streamingPrewarmCandidate(
            model: selectedModel,
            useStreaming: useStreaming,
            isInstalled: { residency.isInstalled($0) }
        ) else {
            let epoch = residency.warmEpoch
            dictationController.afterTeardown { await residency.releaseStreamingModels(ifUnchangedSince: epoch) }
            return
        }
        modelResidency.requestWarm(name, start: activeSideEffects.contains(.dictationHotkey))
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

    nonisolated static func dictationProcessor(for target: DictationTarget?, pieces: DictationProcessorPieces) -> any TextPostProcessor {
        let prompt = pieces.prompt.targeting(target)
        let chain = pieces.before + [prompt] + pieces.after
        return chain.count == 1 ? prompt : CompositePostProcessor(chain)
    }

    private func dictationProcessorPieces() -> DictationProcessorPieces {
        let contextConfig = DictationContextConfig(
            selectionEnabled: dictationContextSelection,
            clipboardEnabled: dictationContextClipboard,
            screenEnabled: dictationContextScreen
        )
        let contextProvider: DictationContextProvider? = contextConfig.isAllDisabled
            ? nil
            : DictationContextProvider(source: MacContextSource())
        var prompt = PromptDictationProcessor(
            defaultPrompt: currentDictationCleanupPrompt(),
            overrides: currentDictationOverrides(),
            triggerPrompts: cachedDictationTriggerPrompts,
            contextProvider: contextProvider,
            contextConfig: contextConfig,
            language: selectedLanguage,
            cleanupRunner: dictationCleanupRunner()
        )
        prompt.scopedContext = { DictationContextProvider(source: MacContextSource(targetProcessID: $0)) }
        var before: [any TextPostProcessor] = []
        if dictationStripSelfCorrections {
            before.append(SelfCorrectionCleaner())
        }
        if correctionRules.contains(where: { $0.enabled && !$0.from.isEmpty }) {
            before.append(CorrectionRuleSet(rules: correctionRules))
        }
        if snippets.contains(where: { $0.enabled }) {
            before.append(makeSnippetExpander())
        }
        var after: [any TextPostProcessor] = []
        // Deferred snippets expand after cleanup so {{CLIPBOARD}}/{{TIME}} read insert-time state.
        if snippets.contains(where: { $0.enabled && $0.expandAtInsert }) {
            after.append(makeSnippetExpander().deferredOnly())
        }
        return DictationProcessorPieces(prompt: prompt, before: before, after: after)
    }

    func dictationPipelineConfiguration() -> DictationPipelineConfiguration {
        let pieces = dictationProcessorPieces()
        let workflows = dictationWorkflows()
        let pasteDelay = max(0, min(2000, dictationPasteDelayMs))
        return DictationPipelineConfiguration(
            modelName: selectedModel,
            language: selectedLanguage,
            initialPrompt: initialPrompt.isEmpty ? nil : initialPrompt,
            deviceUID: preferredInputDeviceUID,
            streamingEnabled: useStreaming,
            workflows: workflows,
            postProcessor: Self.dictationProcessor(for: nil, pieces: pieces),
            pasteDelayMs: pasteDelay,
            bind: { target in
                let workflow = target?.bundleID.flatMap { DictationWorkflowMap.select(in: workflows, for: $0, url: target?.url) }
                let typed = (workflow?.insertion ?? .paste) == .keystroke
                let base: any TextInserter = typed ? KeystrokeTextInserter() : ClipboardPasteInserter()
                return DictationTakeBinding(
                    postProcessor: Self.dictationProcessor(for: target, pieces: pieces),
                    inserter: TargetedTextInserter(base: base, target: target, pasteDelayMs: typed ? 0 : pasteDelay)
                )
            }
        )
    }

    func pressedPipelineConfiguration() -> DictationPipelineConfiguration {
        let configuration = dictationPipelineConfiguration()
        lastDictationModel = configuration.modelName
        return configuration
    }

    func refreshDictationTriggerPrompts() async {
        let user = await promptLibrary.userPrompts
        let prompts = (Prompt.builtIns + user).filter { !$0.triggerWords.isEmpty }
        await MainActor.run {
            self.cachedDictationTriggerPrompts = prompts
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
        dictationController.stop()
    }

    func abortDictation() {
        dictationController.abort()
    }

    func applyIndicatorStyleChange() {
        dictationController.indicatorStyle = dictationIndicatorStyle
    }
}

struct DictationProcessorPieces: Sendable {
    let prompt: PromptDictationProcessor
    let before: [any TextPostProcessor]
    let after: [any TextPostProcessor]
}

struct DictationNoProcessing: TextPostProcessor {
    func process(_ text: String) async -> String { text }
}
