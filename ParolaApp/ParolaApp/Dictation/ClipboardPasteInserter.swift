import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import ParolaCore
import ParolaDictation

struct ClipboardPasteInserter: TextInserter {
    var preDelayMs: Int = 0
    var trustCheck: @Sendable () -> Bool = { AXIsProcessTrusted() }
    var pasteboardName: NSPasteboard.Name = .general

    /// Leaves the dictated text on the pasteboard this long before restoring the prior contents;
    /// must outlast the target app's read of the pasteboard or the insertion is lost.
    private static let restoreDelayMs = 300

    func insert(_ text: String) async throws {
        if preDelayMs > 0 {
            try? await Task.sleep(for: .milliseconds(preDelayMs))
        }
        let prior = await PasteboardSnapshot.capture(named: pasteboardName)
        try await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            guard trustCheck() else {
                ParolaLog.notice(.appPermissions, "text insertion blocked: accessibility not granted")
                throw TextInsertionError.accessibilityDenied
            }
            let changeCountAfterWrite = pasteboard.changeCount
            postCmdV()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Self.restoreDelayMs))
                guard !prior.isEmpty else { return }
                guard pasteboard.changeCount == changeCountAfterWrite else { return }
                prior.restore(to: pasteboard)
            }
        }
    }

    @MainActor
    private func postCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
