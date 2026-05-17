import AppKit
import Carbon.HIToolbox
import Foundation
import ParolaCore

struct KeystrokeTextInserter: TextInserter {
    func insert(_ text: String) async {
        await MainActor.run {
            postKeystrokes(text)
        }
    }

    @MainActor
    private func postKeystrokes(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let utf16Chars = Array(text.utf16)
        for codeUnit in utf16Chars {
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

    func insert(_ text: String) async {
        switch await resolver() {
        case .paste:     await paste.insert(text)
        case .keystroke: await keystroke.insert(text)
        }
    }
}
