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
            .background(PopoverWindowProbe(monitor: monitor).frame(width: 0, height: 0).allowsHitTesting(false))
            .onAppear { [dismiss] in monitor.start { dismiss() } }
            .onDisappear { monitor.stop() }
    }

    nonisolated static func closes(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        targetsPopover: Bool,
        textInputActive: Bool
    ) -> Bool {
        keyCode == 53
            && modifiers.intersection([.command, .option, .control, .shift]).isEmpty
            && targetsPopover
            && !textInputActive
    }
}

private struct PopoverWindowProbe: NSViewRepresentable {
    let monitor: EscapeKeyMonitor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        monitor.probe = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        monitor.probe = nsView
    }
}

@MainActor
private final class EscapeKeyMonitor {
    weak var probe: NSView?
    private weak var keyWindowAtStart: NSWindow?
    private var token: Any?

    func start(onEscape: @escaping () -> Void) {
        guard token == nil else { return }
        keyWindowAtStart = NSApp.keyWindow
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let window = event.window ?? NSApp.keyWindow
            guard let self, PopoverEscape.closes(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                targetsPopover: self.hosts(window),
                textInputActive: (window?.firstResponder as? NSTextView)?.isEditable == true
            ) else { return event }
            onEscape()
            return nil
        }
    }

    // A popover that never takes key leaves Escape with the window it hangs off; any other window keeps its own.
    private func hosts(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        let popoverWindow = probe?.window
        return window === popoverWindow || window === (popoverWindow?.parent ?? keyWindowAtStart)
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}
