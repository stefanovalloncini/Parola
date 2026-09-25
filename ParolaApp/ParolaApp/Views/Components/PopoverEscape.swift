import AppKit
import SwiftUI

extension View {
    /// Escape closes the popover even while clicked transcript text keeps key focus and would swallow the key.
    func closesOnEscape() -> some View {
        modifier(PopoverEscape())
    }
}

struct PopoverEscape: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @State private var monitor = EscapeKeyMonitor()

    func body(content: Content) -> some View {
        content
            .onAppear { [dismiss] in monitor.start { dismiss() } }
            .onDisappear { monitor.stop() }
    }

    nonisolated static func closes(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        textInputActive: Bool,
        sheetInFront: Bool
    ) -> Bool {
        keyCode == 53
            && modifiers.intersection([.command, .option, .control, .shift]).isEmpty
            && !textInputActive
            && !sheetInFront
    }
}

@MainActor
private final class EscapeKeyMonitor {
    private var token: Any?

    func start(onEscape: @escaping () -> Void) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let window = event.window ?? NSApp.keyWindow
            guard self != nil, PopoverEscape.closes(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                textInputActive: (window?.firstResponder as? NSTextView)?.isEditable == true,
                sheetInFront: NSApp.modalWindow != nil || window?.isSheet == true || window?.attachedSheet != nil
            ) else { return event }
            onEscape()
            return nil
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}
