import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import ParolaCore
import ParolaDictation

struct KeystrokeTextInserter: TextInserter {
    var trustCheck: @Sendable () -> Bool = { AXIsProcessTrusted() }

    private static let paceBatchSize = 8

    func insert(_ text: String) async throws {
        guard trustCheck() else {
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
            throw TextInsertionError.accessibilityDenied
        }
        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            let end = min(start + Self.paceBatchSize, units.count)
            let batch = Array(units[start..<end])
            await MainActor.run { postKeystrokes(batch) }
            start = end
            if start < units.count {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    @MainActor
    private func postKeystrokes(_ units: [UInt16]) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for codeUnit in units {
            var unit = codeUnit
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            up?.post(tap: .cghidEventTap)
        }
    }
}

struct PerAppTextInserter: TextInserter {
    let paste: ClipboardPasteInserter
    let keystroke: KeystrokeTextInserter
    let resolver: @Sendable () async -> DictationInsertionMode

    init(
        paste: ClipboardPasteInserter = ClipboardPasteInserter(),
        keystroke: KeystrokeTextInserter = KeystrokeTextInserter(),
        resolver: @escaping @Sendable () async -> DictationInsertionMode
    ) {
        self.paste = paste
        self.keystroke = keystroke
        self.resolver = resolver
    }

    func insert(_ text: String) async throws {
        switch await resolver() {
        case .paste:     try await paste.insert(text)
        case .keystroke: try await keystroke.insert(text)
        }
    }
}
