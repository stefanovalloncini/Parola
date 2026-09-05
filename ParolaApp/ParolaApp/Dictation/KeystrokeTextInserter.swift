import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import ParolaCore
import ParolaDictation

struct KeystrokeTextInserter: TextInserter {
    var trustCheck: @Sendable () -> Bool = { AXIsProcessTrusted() }

    private static let paceBatchSize = 8

    /// Splits only between scalars: a surrogate pair posted across two events arrives
    /// as an unpaired surrogate and renders as U+FFFD in the target app.
    nonisolated static func utf16Batches(of text: String, maxUnits: Int) -> [[UInt16]] {
        var batches: [[UInt16]] = []
        var current: [UInt16] = []
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if !current.isEmpty, current.count + units.count > maxUnits {
                batches.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }

    func insert(_ text: String) async throws {
        guard trustCheck() else {
            ParolaLog.notice(.appPermissions, "keystroke insertion blocked: accessibility not granted")
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
            throw TextInsertionError.accessibilityDenied
        }
        let batches = Self.utf16Batches(of: text, maxUnits: Self.paceBatchSize)
        for (index, batch) in batches.enumerated() {
            await MainActor.run { postKeystrokes(batch) }
            if index < batches.count - 1 {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    @MainActor
    private func postKeystrokes(_ units: [UInt16]) {
        guard !units.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        var buffer = units
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
        // Events inherit the live modifier state: a still-held hotkey modifier would turn
        // an inserted "w" into ⌘W in the target app.
        down?.flags = []
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
        up?.flags = []
        up?.post(tap: .cghidEventTap)
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
