import AppKit
import Carbon.HIToolbox
import Foundation
import ParolaCore

struct ClipboardPasteInserter: TextInserter {
    func insert(_ text: String) async {
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            let priorContents = pasteboard.string(forType: .string)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            postCmdV()
            // Restore prior pasteboard contents after a short delay so the paste lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let priorContents else { return }
                pasteboard.clearContents()
                pasteboard.setString(priorContents, forType: .string)
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
