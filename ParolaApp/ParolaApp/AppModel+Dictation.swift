import Foundation
import SwiftUI
import AppKit
import ParolaCore

extension AppModel {

    func dictationOverridePromptID(for bundleID: String) -> String {
        guard let data = dictationPerAppOverridesJSON.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return ""
        }
        return map[bundleID] ?? ""
    }

    func setDictationOverridePromptID(_ promptID: String, for bundleID: String) {
        var map = (try? JSONDecoder().decode([String: String].self, from: dictationPerAppOverridesJSON.data(using: .utf8) ?? Data())) ?? [:]
        if promptID.isEmpty {
            map.removeValue(forKey: bundleID)
        } else {
            map[bundleID] = promptID
        }
        if let data = try? JSONEncoder().encode(map) {
            dictationPerAppOverridesJSON = String(decoding: data, as: UTF8.self)
        }
    }

    func applyDictationEnabledChange() {
        if dictationEnabled {
            startDictation()
        } else {
            stopDictation()
        }
    }

    func startDictation() {
        guard dictationCoordinator == nil else { return }
        let hotkey = GlobalHotkeyMonitor(keyCode: dictationKeyCode)
        let recorder = MicDictationRecorder(
            model: selectedModel,
            language: selectedLanguage,
            deviceUID: preferredInputDeviceUID
        )
        let inserter = ClipboardPasteInserter()
        let processor = currentDictationProcessor()
        let coord = DictationCoordinator(
            hotkey: hotkey,
            recorder: recorder,
            inserter: inserter,
            postProcessor: processor,
            mode: dictationMode
        ) { [weak self] state in
            await MainActor.run { self?.handleDictationState(state) }
        }
        dictationCoordinator = coord
        Task { await coord.startMonitoring() }
    }

    func applyDictationModeChange() {
        guard let coord = dictationCoordinator else { return }
        let newMode = dictationMode
        Task { await coord.setMode(newMode) }
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
        guard let data = dictationPerAppOverridesJSON.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        var out: [String: Prompt] = [:]
        for (bundleID, promptID) in map {
            if let uuid = UUID(uuidString: promptID),
               let prompt = Prompt.builtIns.first(where: { $0.id == uuid }) {
                out[bundleID] = prompt
            }
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
        guard let coord = dictationCoordinator else { return }
        let processor = currentDictationProcessor()
        Task { await coord.setPostProcessor(processor) }
    }

    func startDictationFromIntent() {
        if !dictationEnabled { dictationEnabled = true }
        guard let coord = dictationCoordinator else { return }
        Task { await coord.simulatePress() }
    }

    func stopDictationFromIntent() {
        guard let coord = dictationCoordinator else { return }
        Task { await coord.simulateRelease() }
    }

    func stopDictation() {
        if let coord = dictationCoordinator {
            Task { await coord.stopMonitoring() }
            dictationCoordinator = nil
        }
        stopDictationPartialStream()
        hideDictationHUD()
        dictationState = .idle
    }

    private func handleDictationState(_ state: DictationCoordinator.State) {
        dictationState = state
        switch state {
        case .idle:
            hideDictationHUD()
        case .listening:
            showDictationHUD(state: state)
            startDictationLevelStream()
            startDictationPartialStream()
        case .transcribing:
            showDictationHUD(state: state)
            stopDictationLevelStream()
        case .failed:
            showDictationHUD(state: state)
            stopDictationLevelStream()
            stopDictationPartialStream()
            Task {
                try? await Task.sleep(for: .seconds(3))
                if case .failed = self.dictationState { self.hideDictationHUD() }
            }
        }
    }

    private func startDictationLevelStream() {
        guard let coord = dictationCoordinator else { return }
        dictationLevelTask?.cancel()
        dictationLevelTask = Task { [weak self] in
            let stream = await coord.levels()
            for await level in stream {
                await MainActor.run {
                    guard let self else { return }
                    if abs(self.dictationAudioLevel - level) > 0.01 {
                        self.dictationAudioLevel = level
                    }
                }
            }
        }
    }

    private func stopDictationLevelStream() {
        dictationLevelTask?.cancel()
        dictationLevelTask = nil
        dictationAudioLevel = 0
    }

    private func startDictationPartialStream() {
        guard let coord = dictationCoordinator else { return }
        dictationPartialTask?.cancel()
        dictationPartialText = ""
        dictationPartialTask = Task { [weak self] in
            let stream = await coord.partials()
            for await text in stream {
                await MainActor.run {
                    guard let self else { return }
                    if self.dictationPartialText != text {
                        self.dictationPartialText = text
                    }
                }
            }
        }
    }

    private func stopDictationPartialStream() {
        dictationPartialTask?.cancel()
        dictationPartialTask = nil
        dictationPartialText = ""
    }

    private func showDictationHUD(state: DictationCoordinator.State) {
        if dictationHUD == nil {
            let model = self
            dictationHUD = DictationHUD.make {
                DictationView(state: model.dictationState, model: model)
            }
        }
        if let panel = dictationHUD {
            if let host = panel.contentView as? NSHostingView<DictationView> {
                host.rootView = DictationView(state: state, model: self)
            }
            resizeDictationHUDForPartial()
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                let panelFrame = panel.frame
                let x = frame.midX - panelFrame.width / 2
                let y = frame.minY + 100
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
            panel.orderFrontRegardless()
        }
    }

    func resizeDictationHUDForPartial() {
        guard let panel = dictationHUD else { return }
        let hasPartial = !dictationPartialText.isEmpty
        let target = NSSize(
            width: hasPartial ? 332 : 268,
            height: hasPartial ? 78 : 64
        )
        guard panel.frame.size != target else { return }
        var newFrame = panel.frame
        let oldCenterX = newFrame.midX
        newFrame.size = target
        newFrame.origin.x = oldCenterX - target.width / 2
        panel.setFrame(newFrame, display: true, animate: true)
    }

    private func hideDictationHUD() {
        stopDictationLevelStream()
        dictationHUD?.orderOut(nil)
    }
}
