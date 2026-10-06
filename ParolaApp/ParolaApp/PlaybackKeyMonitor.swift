import AppKit

enum PlaybackKeyAction: Equatable {
    case togglePlayPause
    case skipBack
    case skipForward
    case toggleTakePause
    /// Space held on the Stage: the press toggled the take once, and its repeats end here.
    case swallowRepeat
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
        stageShowsTake: Bool = false,
        isRepeat: Bool = false,
        focusedControlTakesSpace: Bool = false
    ) -> PlaybackKeyAction? {
        guard !textInputActive else { return nil }
        let relevant = modifiers.intersection([.command, .option, .control, .shift])
        // A transcript loaded before the take keeps its player; on the Stage, Space belongs to the take or a focused control.
        if stageShowsTake, keyCode == 49, relevant.isEmpty {
            guard !focusedControlTakesSpace else { return nil }
            return isRepeat ? .swallowRepeat : .toggleTakePause
        }
        guard hasPlayer else { return nil }
        switch (keyCode, relevant) {
        case (49, []): return .togglePlayPause
        case (123, [.command]): return .skipBack
        case (124, [.command]): return .skipForward
        default: return nil
        }
    }

    /// A key press in one of Parola's windows; true when it was used up here.
    static func handle(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isRepeat: Bool = false,
        firstResponder: NSResponder?,
        inMainWindow: Bool,
        model: AppModel
    ) -> Bool {
        guard let action = Self.action(
            keyCode: keyCode,
            modifiers: modifiers,
            textInputActive: (firstResponder as? NSTextView)?.isEditable == true,
            hasPlayer: model.keyWindowHasPlayer,
            stageShowsTake: inMainWindow && stageShowsTake(model),
            isRepeat: isRepeat,
            focusedControlTakesSpace: takesSpace(firstResponder)
        ) else { return false }
        switch action {
        case .togglePlayPause: model.togglePlayPauseInKeyWindow()
        case .skipBack: model.skipInKeyWindow(by: PlaybackSkip.back.seconds)
        case .skipForward: model.skipInKeyWindow(by: PlaybackSkip.forward.seconds)
        case .toggleTakePause: StageControls.togglePause(model)
        case .swallowRepeat: break
        }
        return true
    }

    /// A control with keyboard focus that Space presses, as Full Keyboard Access gives one.
    static func takesSpace(_ responder: NSResponder?) -> Bool {
        if responder is NSButton || responder is NSSegmentedControl { return true }
        // SwiftUI's stand-in in the key view loop for whichever of its controls has focus (macOS 26 and 27).
        return responder.map { String(describing: type(of: $0)) == "KeyViewProxy" } ?? false
    }

    /// Whenever the Stage shows its take, from the count-in through its transcription: the Stage owns Space all that time.
    static func stageShowsTake(_ model: AppModel) -> Bool {
        ContentRoutes.stageIsUp(model)
    }

    func bind(_ model: AppModel) {
        guard monitor == nil else { return }
        self.model = model
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let model = self?.model else { return event }
            let window = event.window ?? NSApp.keyWindow
            let used = Self.handle(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                isRepeat: event.isARepeat,
                firstResponder: window?.firstResponder,
                inMainWindow: window != nil && window === model.mainWindow,
                model: model
            )
            return used ? nil : event
        }
    }
}
