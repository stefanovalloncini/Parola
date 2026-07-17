import AppKit
import Foundation
import ParolaDictation

@MainActor
final class MicHotkeyController {
    private weak var model: AppModel?
    private(set) var monitor: (any HotkeyMonitor)?
    var monitorFactory: (Int, NSEvent.ModifierFlags) -> any HotkeyMonitor = {
        GlobalHotkeyMonitor(keyCode: $0, modifiers: $1)
    }
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

    func applyConfiguration(enabled: Bool, keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        if let last = lastConfig, last.enabled == enabled, last.code == keyCode, last.mods == modifiers {
            return
        }
        lastConfig = (enabled, keyCode, modifiers)
        configureTask?.cancel()
        configureTask = Task { [weak self] in
            guard let self else { return }
            if let current = self.monitor {
                await current.stop()
                // A superseded apply resuming here used to nil the monitor the newer
                // apply had just installed, leaving the hotkey silently dead.
                if Task.isCancelled { return }
                if self.monitor === current { self.monitor = nil }
            }
            if Task.isCancelled { return }
            guard enabled else { return }
            let monitor = monitorFactory(keyCode, modifiers)
            self.monitor = monitor
            await monitor.start { [weak self] event in
                guard case .press = event else { return }
                Task { @MainActor in self?.model?.toggleMicRecording() }
            }
            if Task.isCancelled {
                await monitor.stop()
            }
        }
    }
}
