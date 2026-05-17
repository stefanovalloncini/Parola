import AppKit
import Combine
import ParolaCore

@MainActor
final class DictationStatusItem {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private var cancellable: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        apply(state: model.dictationState)
        cancellable = model.$dictationState.sink { [weak self] state in
            self?.apply(state: state)
        }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick)
    }

    private func apply(state: DictationCoordinator.State) {
        guard let button = statusItem.button else { return }
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
            if !model.dictationEnabled {
                model.dictationEnabled = true
            }
            model.startDictationFromIntent()
        }
    }
}
