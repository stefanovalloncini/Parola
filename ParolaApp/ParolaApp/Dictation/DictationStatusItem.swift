import AppKit
import ParolaCore
import ParolaDictation

@MainActor
final class DictationStatusItem {
    private let model: AppModel
    private var statusItem: NSStatusItem?
    private var lastVisibility = false

    init(model: AppModel) {
        self.model = model
        applyVisibility(model.dictationEnabled)
        lastVisibility = model.dictationEnabled
        observeState()
    }

    private func observeState() {
        withObservationTracking {
            _ = model.dictationState
            _ = model.dictationEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.observeState()
            }
        }
        apply(state: model.dictationState)
    }

    private func refresh() {
        if model.dictationEnabled != lastVisibility {
            applyVisibility(model.dictationEnabled)
            lastVisibility = model.dictationEnabled
        }
        apply(state: model.dictationState)
    }

    private func applyVisibility(_ visible: Bool) {
        if visible {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem = item
            configureButton()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func configureButton() {
        guard let button = statusItem?.button else { return }
        button.target = self
        button.action = #selector(handleClick)
    }

    private func apply(state: DictationCoordinator.State) {
        guard let button = statusItem?.button else { return }
        let label = tooltip(for: state)
        let image = NSImage(systemSymbolName: symbolName(for: state), accessibilityDescription: label)
        image?.isTemplate = true
        button.image = image
        button.toolTip = label
    }

    private func symbolName(for state: DictationCoordinator.State) -> String {
        switch state {
        case .idle: return "mic"
        case .listening: return "mic.fill"
        case .transcribing: return "waveform"
        case .failed: return "mic.slash"
        }
    }

    private func tooltip(for state: DictationCoordinator.State) -> String {
        switch state {
        case .idle: return "Dictation: ready"
        case .listening: return "Dictation: listening"
        case .transcribing: return "Dictation: transcribing"
        case .failed: return "Dictation: error"
        }
    }

    @objc private func handleClick() {
        switch model.dictationState {
        case .listening:
            model.stopDictationFromIntent()
        case .idle, .transcribing, .failed:
            model.startDictationFromIntent()
        }
    }
}
