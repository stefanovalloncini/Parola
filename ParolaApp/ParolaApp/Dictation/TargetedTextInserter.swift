import AppKit
import Foundation
import ParolaDictation

struct TargetedTextInserter: TextInserter {
    let base: any TextInserter
    let target: DictationTarget?
    var pasteDelayMs = 0
    var frontmostProcessID: @Sendable () async -> Int32? = {
        await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    }
    var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    var pasteboardName: NSPasteboard.Name = .general

    func insert(_ text: String) async throws {
        if pasteDelayMs > 0 { await sleep(.milliseconds(pasteDelayMs)) }
        guard var paste = base as? ClipboardPasteInserter else {
            try await verifyTarget(copying: text)
            try await base.insert(text)
            return
        }
        paste.beforePaste = { try await verifyTarget(copying: text) }
        try await paste.insert(text)
    }

    private func verifyTarget(copying text: String) async throws {
        guard let target, let current = await frontmostProcessID(), current != target.processID else { return }
        await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        throw TextInsertionError.targetChanged
    }
}
