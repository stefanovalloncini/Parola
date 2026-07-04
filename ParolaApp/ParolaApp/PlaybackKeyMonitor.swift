import AppKit

enum PlaybackKeyAction: Equatable {
    case togglePlayPause
    case skipBack
    case skipForward
}

@MainActor
final class PlaybackKeyMonitor {
    private var monitor: Any?
    private weak var model: AppModel?

    nonisolated static func action(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        textInputActive: Bool,
        hasPlayer: Bool
    ) -> PlaybackKeyAction? {
        guard hasPlayer, !textInputActive else { return nil }
        let relevant = modifiers.intersection([.command, .option, .control, .shift])
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
            let responder = (event.window ?? NSApp.keyWindow)?.firstResponder
            let textInputActive = (responder as? NSTextView)?.isEditable == true
            guard let action = Self.action(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                textInputActive: textInputActive,
                hasPlayer: model.player != nil
            ) else { return event }
            switch action {
            case .togglePlayPause: model.togglePlayPause()
            case .skipBack: model.skip(by: -5)
            case .skipForward: model.skip(by: 5)
            }
            return nil
        }
    }
}
