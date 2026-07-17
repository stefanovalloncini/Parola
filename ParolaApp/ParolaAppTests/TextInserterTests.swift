import AppKit
import Foundation
import Testing
@testable import Parola

@Suite("Text inserters", .serialized)
struct TextInserterTests {
    private func withPasteboardRestored(_ body: () async throws -> Void) async rethrows {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        try await body()
    }

    @Test("untrusted paste leaves the text on the clipboard and throws")
    func untrustedPaste() async throws {
        try await withPasteboardRestored {
            let inserter = ClipboardPasteInserter(trustCheck: { false })
            var thrown: Error?
            do {
                try await inserter.insert("dictated text")
            } catch {
                thrown = error
            }
            #expect(thrown is TextInsertionError)
            await MainActor.run {
                #expect(NSPasteboard.general.string(forType: .string) == "dictated text")
            }
            try await Task.sleep(for: .milliseconds(450))
            await MainActor.run {
                #expect(NSPasteboard.general.string(forType: .string) == "dictated text")
            }
        }
    }

    @Test("untrusted keystrokes fall back to the clipboard and throw")
    func untrustedKeystrokes() async throws {
        await withPasteboardRestored {
            let inserter = KeystrokeTextInserter(trustCheck: { false })
            var thrown: Error?
            do {
                try await inserter.insert("typed text")
            } catch {
                thrown = error
            }
            #expect(thrown is TextInsertionError)
            await MainActor.run {
                #expect(NSPasteboard.general.string(forType: .string) == "typed text")
            }
        }
    }

    @Test("the error explains the clipboard recovery")
    func errorCopy() {
        let message = TextInsertionError.accessibilityDenied.localizedDescription
        #expect(message.contains("⌘V"))
    }
}
