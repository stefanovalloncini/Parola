import AppKit
import SwiftUI

@MainActor
@Observable
final class ScratchpadController {
    var text: String = ""

    @ObservationIgnored private var panel: NSPanel?

    var isOpen: Bool { panel != nil }

    func toggle() {
        if panel == nil {
            open()
        } else {
            close()
        }
    }

    func clear() {
        text = ""
    }

    func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func open() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 280),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        p.title = "Scratchpad"
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        p.center()
        p.contentView = NSHostingView(rootView: ScratchpadView(controller: self))
        p.delegate = ScratchpadController.WindowCloseProxy.shared
        ScratchpadController.WindowCloseProxy.shared.onClose = { [weak self] in self?.panel = nil }
        panel = p
        p.makeKeyAndOrderFront(nil)
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    @MainActor
    private final class WindowCloseProxy: NSObject, NSWindowDelegate {
        static let shared = WindowCloseProxy()
        var onClose: (() -> Void)?

        func windowWillClose(_ notification: Notification) {
            onClose?()
        }
    }
}
