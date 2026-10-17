import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import ParolaCore
import os
import ParolaDictation

/// The prior clipboard of a paste whose restore has not run yet, so the next paste can take it over instead of snapshotting our own text.
enum PendingPasteRestores {
    struct Pending: Sendable {
        let prior: PasteboardSnapshot
        let changeCount: Int
        let task: Task<Void, Never>
    }

    private static let state = OSAllocatedUnfairLock<[NSPasteboard.Name: Pending]>(initialState: [:])

    static func set(_ pending: Pending?, on name: NSPasteboard.Name) {
        state.withLock { $0[name] = pending }
    }

    static func takeReusablePrior(on name: NSPasteboard.Name) -> PasteboardSnapshot? {
        guard let pending = state.withLock({ $0.removeValue(forKey: name) }) else { return nil }
        pending.task.cancel()
        return NSPasteboard(name: name).changeCount == pending.changeCount ? pending.prior : nil
    }

    /// What the user has copied: while a restore is pending and nothing else has written since the paste, that is the prior clipboard, not our pasted text.
    static func userText(on name: NSPasteboard.Name = .general) -> String? {
        let pasteboard = NSPasteboard(name: name)
        if let pending = state.withLock({ $0[name] }), pasteboard.changeCount == pending.changeCount {
            return pending.prior.plainText
        }
        return pasteboard.string(forType: .string)
    }
}

struct ClipboardPasteInserter: TextInserter {
    var preDelayMs: Int = 0
    var trustCheck: @Sendable () -> Bool = { AXIsProcessTrusted() }
    var pasteboardName: NSPasteboard.Name = .general
    var restoreDelay: Duration = .milliseconds(300)
    var postPaste: @MainActor @Sendable () -> Void = { ClipboardPasteInserter.postCmdV() }
    var beforePaste: (@Sendable () async throws -> Void)?

    func insert(_ text: String) async throws {
        if preDelayMs > 0 {
            try? await Task.sleep(for: .milliseconds(preDelayMs))
        }
        let name = pasteboardName
        let reused = await MainActor.run { PendingPasteRestores.takeReusablePrior(on: name) }
        let prior: PasteboardSnapshot
        if let reused {
            prior = reused
        } else {
            prior = await PasteboardSnapshot.capture(named: name)
        }
        try await beforePaste?()
        try await MainActor.run {
            let pasteboard = NSPasteboard(name: name)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            guard trustCheck() else {
                ParolaLog.notice(.appPermissions, "text insertion blocked: accessibility not granted")
                throw TextInsertionError.accessibilityDenied
            }
            let changeCountAfterWrite = pasteboard.changeCount
            postPaste()
            guard !prior.isEmpty else { return }
            // Must outlast the target app's read of the pasteboard or the insertion is lost.
            let delay = restoreDelay
            let restore = Task { @MainActor in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                PendingPasteRestores.set(nil, on: name)
                guard pasteboard.changeCount == changeCountAfterWrite else { return }
                prior.restore(to: pasteboard)
            }
            PendingPasteRestores.set(.init(prior: prior, changeCount: changeCountAfterWrite, task: restore), on: name)
        }
    }

    @MainActor
    fileprivate static func postCmdV() {
        let (down, up) = cmdVEvents()
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    nonisolated static func cmdVEvents() -> (down: CGEvent?, up: CGEvent?) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        return (down, up)
    }
}
