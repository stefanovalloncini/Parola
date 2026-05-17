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
            let changeCountAfterWrite = pasteboard.changeCount
            postCmdV()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard let priorContents else { return }
                guard pasteboard.changeCount == changeCountAfterWrite else { return }
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
