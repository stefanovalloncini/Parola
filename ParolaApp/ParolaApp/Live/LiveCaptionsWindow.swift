import AppKit
import SwiftUI

enum LiveCaptionsWindow {
    nonisolated static func title(bundle: Bundle = .main) -> String {
        String(localized: "Live Captions", bundle: bundle)
    }

    @MainActor
    static func make<Content: View>(@ViewBuilder content: @escaping () -> Content) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 96),
            styleMask: [.nonactivatingPanel, .hudWindow, .titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = title()
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: content())
        return panel
    }
}
