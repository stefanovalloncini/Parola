import AppKit
import SwiftUI

/// Reads the arrow, Return and Delete keys for the Recent shelf while the list has the keyboard; the table keeps the responder, so a local monitor sees them first.
struct ShelfKeyMonitor: NSViewRepresentable {
    let isActive: Bool
    let handle: (RecentShelfRules.Key) -> Bool

    static func key(for event: NSEvent) -> RecentShelfRules.Key? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .option, event.keyCode == 36 || event.keyCode == 76 { return .optionReturn }
        guard modifiers.isEmpty else { return nil }
        switch event.keyCode {
        case 123: return .left
        case 124: return .right
        case 126: return .up
        case 125: return .down
        case 36, 76: return .return
        case 51, 117: return .delete
        default: return nil
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.handle = handle
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var isActive = false
        var handle: (RecentShelfRules.Key) -> Bool = { _ in false }
        private var monitor: Any?

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, MainActor.assumeIsolated({ self.consumes(event) }) else { return event }
                return nil
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// True when the window's first responder is a table inside one of the monitor view's nearest containers, which is the list it belongs to and not a covered one elsewhere.
        private func listHasKeyboard(in window: NSWindow, near view: NSView) -> Bool {
            guard let table = window.firstResponder as? NSTableView else { return false }
            var container: NSView? = view
            for _ in 0..<4 {
                container = container?.superview
                if let container, table.isDescendant(of: container) { return true }
            }
            return false
        }

        private func consumes(_ event: NSEvent) -> Bool {
            guard isActive, let view, let window = view.window, event.window === window,
                  listHasKeyboard(in: window, near: view),
                  let key = ShelfKeyMonitor.key(for: event) else { return false }
            return handle(key)
        }
    }
}
