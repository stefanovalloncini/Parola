import AppKit

enum PlaybackKeyAction: Equatable {
    case togglePlayPause
    case skipBack
    case skipForward
    case toggleTakePause
}

@MainActor
final class PlaybackKeyMonitor {
    private var monitor: Any?
    private weak var model: AppModel?

    nonisolated static func action(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        textInputActive: Bool,
        hasPlayer: Bool,
        stageShowsTake: Bool = false
    ) -> PlaybackKeyAction? {
        guard !textInputActive else { return nil }
        let relevant = modifiers.intersection([.command, .option, .control, .shift])
        // A transcript loaded before the take keeps its player; on the Stage, Space belongs to the take.
        if stageShowsTake, keyCode == 49, relevant.isEmpty { return .toggleTakePause }
        guard hasPlayer else { return nil }
        switch (keyCode, relevant) {
        case (49, []): return .togglePlayPause
        case (123, [.command]): return .skipBack
        case (124, [.command]): return .skipForward
        default: return nil
        }
    }

    func bind(_ model: AppModel) {
        guard monitor == nil else { return }
        self.model = model
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model else { return event }
            let window = event.window ?? NSApp.keyWindow
            let textInputActive = (window?.firstResponder as? NSTextView)?.isEditable == true
            let stageShowsTake = model.route == .recording && model.recording?.isCapturing == true
                && window != nil && window === model.mainWindow
            guard let action = Self.action(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                textInputActive: textInputActive,
                hasPlayer: model.player != nil,
                stageShowsTake: stageShowsTake
            ) else { return event }
            switch action {
            case .togglePlayPause: model.togglePlayPause()
            case .skipBack: model.skip(by: -5)
            case .skipForward: model.skip(by: 5)
            case .toggleTakePause: StageControls.togglePause(model)
            }
            return nil
        }
    }
}
