import Combine
import Foundation
import SwiftUI
import AppKit
import ParolaCore

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
        setDefaultDictationWorkflow(workflow, for: bundleID)
    }

    func removeDictationOverride(for bundleID: String) {
        var map = dictationWorkflows()
        map.removeValue(forKey: bundleID)
        writeDictationWorkflows(map)
    }

    func addDictationURLRule(for bundleID: String) {
        var map = dictationWorkflows()
        var entries = map[bundleID] ?? []
        entries.append(DictationWorkflow(urlPattern: ""))
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
        let workflow = defaultDictationWorkflow(for: bundleID)
        if workflow.isEmpty {
            setDefaultDictationWorkflow(DictationWorkflow(promptID: ""), for: bundleID)
        }
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
        dictationController.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.dictationState = state }
            .store(in: &dictationCancellables)
    }

    func restartDictation() {
        guard dictationEnabled, dictationController.isRunning else { return }
        stopDictation()
        startDictation()
    }

    func applyDictationEnabledChange() {
        if dictationEnabled {
            startDictation()
        } else {
            stopDictation()
        }
    }

    func startDictation() {
        guard !dictationController.isRunning else { return }
        let configuration = DictationController.Configuration(
            modelName: selectedModel,
            language: selectedLanguage,
            deviceUID: preferredInputDeviceUID,
            streamingEnabled: useStreaming,
            hotkeyKeyCode: dictationKeyCode,
            hotkeyModifiers: dictationModifierFlags,
            mode: dictationMode,
            workflows: dictationWorkflows(),
            postProcessor: currentDictationProcessor(),
            pasteDelayMs: max(0, min(2000, dictationPasteDelayMs))
        )
        dictationController.indicatorStyle = dictationIndicatorStyle
        dictationController.start(configuration: configuration)
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
            contextConfig: contextConfig
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
        return chain.count == 1 ? prompt : CompositePostProcessor(chain)
    }

    func applyDictationCleanupPromptChange() {
        guard dictationController.isRunning else { return }
        dictationController.setPostProcessor(currentDictationProcessor())
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
        if !dictationEnabled { dictationEnabled = true }
        dictationController.simulatePress()
    }

    func stopDictationFromIntent() {
        dictationController.simulateRelease()
    }

    func stopDictation() {
        dictationController.stop()
    }

    func applyIndicatorStyleChange() {
        dictationController.indicatorStyle = dictationIndicatorStyle
    }
}
