import AppKit
import Foundation

@MainActor
final class MicHotkeyController {
    private weak var model: AppModel?
    private var monitor: GlobalHotkeyMonitor?
    private var lastConfig: (enabled: Bool, code: Int, mods: NSEvent.ModifierFlags)?
    private var reapplyPending = false
    private var configureTask: Task<Void, Never>?

    func bind(_ model: AppModel) {
        configureTask?.cancel()
        lastConfig = nil
        self.model = model
        observeAndApply()
    }

    private func observeAndApply() {
        guard let model else { return }
        withObservationTracking {
            _ = model.micHotkeyEnabled
            _ = model.micHotkeyKeyCode
            _ = model.micHotkeyModifiers
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleReapply() }
        }
        applyConfiguration(
            enabled: model.micHotkeyEnabled,
            keyCode: model.micHotkeyKeyCode,
            modifiers: model.micHotkeyModifierFlags
        )
    }

    private func scheduleReapply() {
        guard !reapplyPending else { return }
        reapplyPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reapplyPending = false
            self.observeAndApply()
        }
    }

    private func applyConfiguration(enabled: Bool, keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        if let last = lastConfig, last.enabled == enabled, last.code == keyCode, last.mods == modifiers {
            return
        }
        lastConfig = (enabled, keyCode, modifiers)
        configureTask?.cancel()
        configureTask = Task { [weak self] in
            guard let self else { return }
            if let monitor = self.monitor {
                await monitor.stop()
                self.monitor = nil
            }
            if Task.isCancelled { return }
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
