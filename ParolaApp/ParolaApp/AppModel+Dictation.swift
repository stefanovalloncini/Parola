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
        let hotkey = F5HotkeyMonitor()
        let recorder = MicDictationRecorder(model: selectedModel, language: selectedLanguage)
        let inserter = ClipboardPasteInserter()
        let processor = currentDictationProcessor()
        let coord = DictationCoordinator(
            hotkey: hotkey,
            recorder: recorder,
            inserter: inserter,
            postProcessor: processor
        ) { [weak self] state in
            await MainActor.run { self?.handleDictationState(state) }
        }
        dictationCoordinator = coord
        Task { await coord.startMonitoring() }
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

    private func currentDictationProcessor() -> PromptDictationProcessor {
        PromptDictationProcessor(
            defaultPrompt: currentDictationCleanupPrompt(),
            overrides: currentDictationOverrides()
        )
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
        hideDictationHUD()
        dictationState = .idle
    }

    private func handleDictationState(_ state: DictationCoordinator.State) {
        dictationState = state
        switch state {
        case .idle:
            hideDictationHUD()
        case .listening, .transcribing:
            showDictationHUD(state: state)
        case .failed:
            showDictationHUD(state: state)
            Task {
                try? await Task.sleep(for: .seconds(3))
                if case .failed = self.dictationState { self.hideDictationHUD() }
            }
        }
    }

    private func showDictationHUD(state: DictationCoordinator.State) {
        if dictationHUD == nil {
            dictationHUD = DictationHUD.make { [weak self] in
                DictationView(state: self?.dictationState ?? .idle)
            }
        }
        if let panel = dictationHUD {
            if let host = panel.contentView as? NSHostingView<DictationView> {
                host.rootView = DictationView(state: state)
            }
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

    private func hideDictationHUD() {
        dictationHUD?.orderOut(nil)
    }
}
