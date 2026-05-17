import Combine
import Foundation
import SwiftUI
import AppKit
import ParolaCore

extension AppModel {

    func dictationWorkflows() -> [String: DictationWorkflow] {
        guard let data = dictationPerAppOverridesJSON.data(using: .utf8) else { return [:] }
        return DictationWorkflowMap.decode(legacy: data)
    }

    func dictationWorkflow(for bundleID: String) -> DictationWorkflow {
        dictationWorkflows()[bundleID] ?? DictationWorkflow()
    }

    func setDictationWorkflow(_ workflow: DictationWorkflow, for bundleID: String) {
        var map = dictationWorkflows()
        if workflow.isEmpty {
            map.removeValue(forKey: bundleID)
        } else {
            map[bundleID] = workflow
        }
        let data = DictationWorkflowMap.encode(map)
        dictationPerAppOverridesJSON = String(decoding: data, as: UTF8.self)
    }

    func dictationOverridePromptID(for bundleID: String) -> String {
        dictationWorkflow(for: bundleID).promptID ?? ""
    }

    func setDictationOverridePromptID(_ promptID: String, for bundleID: String) {
        var workflow = dictationWorkflow(for: bundleID)
        workflow.promptID = promptID.isEmpty ? nil : promptID
        setDictationWorkflow(workflow, for: bundleID)
    }

    func dictationOverrideLanguage(for bundleID: String) -> String {
        dictationWorkflow(for: bundleID).language ?? ""
    }

    func setDictationOverrideLanguage(_ language: String, for bundleID: String) {
        var workflow = dictationWorkflow(for: bundleID)
        workflow.language = language.isEmpty ? nil : language
        setDictationWorkflow(workflow, for: bundleID)
    }

    func dictationOverrideInsertion(for bundleID: String) -> DictationInsertionMode {
        dictationWorkflow(for: bundleID).insertion ?? .paste
    }

    func setDictationOverrideInsertion(_ mode: DictationInsertionMode, for bundleID: String) {
        var workflow = dictationWorkflow(for: bundleID)
        workflow.insertion = (mode == .paste) ? nil : mode
        setDictationWorkflow(workflow, for: bundleID)
    }

    func removeDictationOverride(for bundleID: String) {
        var map = dictationWorkflows()
        map.removeValue(forKey: bundleID)
        let data = DictationWorkflowMap.encode(map)
        dictationPerAppOverridesJSON = String(decoding: data, as: UTF8.self)
    }

    func presentAddDictationAppPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Pick an app to give it a custom dictation workflow."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        var workflow = dictationWorkflow(for: bundleID)
        if workflow.isEmpty {
            workflow.promptID = ""
            setDictationWorkflow(workflow, for: bundleID)
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
        observeDictationController()
    }

    private func observeDictationController() {
        dictationController.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.dictationState = state }
            .store(in: &dictationCancellables)
        dictationController.$audioLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in self?.dictationAudioLevel = level }
            .store(in: &dictationCancellables)
        dictationController.$partialText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in self?.dictationPartialText = text }
            .store(in: &dictationCancellables)
    }

    func restartDictationForWorkflowChange() {
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
            postProcessor: currentDictationProcessor()
        )
        dictationController.indicatorStyle = dictationIndicatorStyle
        dictationController.start(configuration: configuration)
    }

    func applyDictationModeChange() {
        dictationController.setMode(dictationMode)
    }

    func restartDictationForKeyChange() {
        guard dictationEnabled else { return }
        stopDictation()
        startDictation()
    }

    private func currentDictationCleanupPrompt() -> Prompt? {
        guard let uuid = UUID(uuidString: dictationCleanupPromptID) else { return nil }
        return Prompt.builtIns.first { $0.id == uuid }
    }

    private func currentDictationOverrides() -> [String: Prompt] {
        var out: [String: Prompt] = [:]
        for (bundleID, workflow) in dictationWorkflows() {
            guard let promptID = workflow.promptID,
                  let uuid = UUID(uuidString: promptID),
                  let prompt = Prompt.builtIns.first(where: { $0.id == uuid }) else {
                continue
            }
            out[bundleID] = prompt
        }
        return out
    }

    private func currentDictationProcessor() -> any TextPostProcessor {
        let prompt = PromptDictationProcessor(
            defaultPrompt: currentDictationCleanupPrompt(),
            overrides: currentDictationOverrides()
        )
        let snippetExpander = makeSnippetExpander()
        if snippets.contains(where: { $0.enabled }) {
            return CompositePostProcessor([snippetExpander, prompt])
        }
        return prompt
    }

    func applyDictationCleanupPromptChange() {
        guard dictationController.isRunning else { return }
        dictationController.setPostProcessor(currentDictationProcessor())
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
