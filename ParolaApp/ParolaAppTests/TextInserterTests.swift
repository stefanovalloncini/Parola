import AppKit
import Foundation
import Testing
@testable import Parola

@Suite("Text inserters", .serialized)
struct TextInserterTests {
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

    @Test("utf16 batches never split a surrogate pair")
    func batchesKeepScalarsWhole() {
        let text = "1234567😀"
        let batches = KeystrokeTextInserter.utf16Batches(of: text, maxUnits: 8)
        for batch in batches {
            if let last = batch.last {
                #expect(!(0xD800...0xDBFF).contains(last), "batch ends with an unpaired high surrogate")
            }
        }
        #expect(batches.flatMap(\.self) == Array(text.utf16))
    }

    @Test("utf16 batches respect the size cap and round-trip in order")
    func batchesCapAndRoundTrip() {
        let ascii = String(repeating: "a", count: 20)
        #expect(KeystrokeTextInserter.utf16Batches(of: ascii, maxUnits: 8).map(\.count) == [8, 8, 4])

        let emoji = String(repeating: "👍", count: 5)
        let batches = KeystrokeTextInserter.utf16Batches(of: emoji, maxUnits: 8)
        #expect(batches.allSatisfy { $0.count <= 8 && $0.count % 2 == 0 })
        #expect(batches.flatMap(\.self) == Array(emoji.utf16))

        #expect(KeystrokeTextInserter.utf16Batches(of: "", maxUnits: 8).isEmpty)
    }
}
