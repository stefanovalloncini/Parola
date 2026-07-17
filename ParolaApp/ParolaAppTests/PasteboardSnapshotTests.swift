import AppKit
import Foundation
import Testing
@testable import Parola

@MainActor
@Suite("Pasteboard snapshot")
struct PasteboardSnapshotTests {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("snapshot-test-\(UUID())"))
    }

    @Test("round-trips an item with multiple representations")
    func roundTripsMultipleTypes() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data([1, 2, 3]), forType: .png)
        item.setString("hello", forType: .string)
        pasteboard.writeObjects([item])

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("dictated", forType: .string)

        snapshot.restore(to: pasteboard)
        #expect(pasteboard.pasteboardItems?.first?.data(forType: .png) == Data([1, 2, 3]))
        #expect(pasteboard.string(forType: .string) == "hello")
    }

    @Test("an empty pasteboard snapshots as empty")
    func emptySnapshot() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        #expect(snapshot.isEmpty)
    }

    @Test("oversized content falls back to the plain-text representation")
    func byteBudgetFallsBackToString() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data(count: 4096), forType: .png)
        item.setString("keep me", forType: .string)
        pasteboard.writeObjects([item])

        let snapshot = PasteboardSnapshot.capture(from: pasteboard, byteBudget: 128)
        pasteboard.clearContents()
        snapshot.restore(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "keep me")
        #expect(pasteboard.pasteboardItems?.first?.data(forType: .png) == nil)
    }
}
