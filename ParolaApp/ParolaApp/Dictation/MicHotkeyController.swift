import AppKit
import Combine
import Foundation

@MainActor
final class MicHotkeyController {
    private weak var model: AppModel?
    private var monitor: GlobalHotkeyMonitor?
    private var cancellables: Set<AnyCancellable> = []
    private var lastConfig: (enabled: Bool, code: Int, mods: NSEvent.ModifierFlags)?

    func bind(_ model: AppModel) {
        self.model = model
        reapplyFromModel()

        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.reapplyFromModel() }
            }
            .store(in: &cancellables)
    }

    private func reapplyFromModel() {
        guard let model else { return }
        applyConfiguration(
            enabled: model.micHotkeyEnabled,
            keyCode: model.micHotkeyKeyCode,
            modifiers: model.micHotkeyModifierFlags
        )
    }

    private func applyConfiguration(enabled: Bool, keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        if let last = lastConfig, last.enabled == enabled, last.code == keyCode, last.mods == modifiers {
            return
        }
        lastConfig = (enabled, keyCode, modifiers)
        Task { [weak self] in
            guard let self else { return }
            if let monitor = self.monitor {
                await monitor.stop()
                self.monitor = nil
            }
            guard enabled else { return }
            let monitor = GlobalHotkeyMonitor(keyCode: keyCode, modifiers: modifiers)
            self.monitor = monitor
            await monitor.start { [weak self] event in
                guard case .press = event else { return }
                Task { @MainActor in self?.model?.toggleMicRecording() }
            }
        }
    }
}
