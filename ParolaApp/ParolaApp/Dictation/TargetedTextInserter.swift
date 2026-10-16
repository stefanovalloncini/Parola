import AppKit
import Foundation
import ParolaDictation

struct TargetedTextInserter: TextInserter {
    let base: any TextInserter
    let target: DictationTarget?
    var frontmostProcessID: @Sendable () async -> Int32? = {
        await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    }
    var pasteboardName: NSPasteboard.Name = .general

    func insert(_ text: String) async throws {
        if let target, let current = await frontmostProcessID(), current != target.processID {
            await MainActor.run {
                let pasteboard = NSPasteboard(name: pasteboardName)
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
            throw TextInsertionError.targetChanged
        }
        try await base.insert(text)
    }
}
