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

    private final class SlowProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var served: [(type: String, onMain: Bool)] = []
        let size: Int
        let started: AsyncStream<Void>
        private let startedContinuation: AsyncStream<Void>.Continuation
        private let gate = DispatchSemaphore(value: 0)
        init(size: Int, blocking: Bool = false) {
            self.size = size
            self.blocking = blocking
            (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        }
        let blocking: Bool
        func open() { gate.signal() }
        var requests: [(type: String, onMain: Bool)] { lock.withLock { served } }
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            lock.withLock { served.append((type.rawValue, Thread.isMainThread)) }
            startedContinuation.yield()
            if blocking { gate.wait() }
            item.setData(Data(count: size), forType: type)
        }
    }

    @Test("a slow clipboard is read off the main actor")
    func captureLeavesMainFree() async {
        let name = NSPasteboard.Name("snapshot-test-\(UUID())")
        let pasteboard = NSPasteboard(name: name)
        pasteboard.clearContents()
        let provider = SlowProvider(size: 16, blocking: true)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png])
        pasteboard.writeObjects([item])

        async let snapshot = PasteboardSnapshot.capture(named: name)
        var started = provider.started.makeAsyncIterator()
        await started.next()
        await MainActor.run {}
        provider.open()
        #expect(await snapshot.isEmpty == false)
        #expect(provider.requests.allSatisfy { !$0.onMain })
    }

    @Test("once the budget is exceeded the remaining representations are not read")
    func overBudgetStopsReading() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        let big = SlowProvider(size: 4096)
        let after = SlowProvider(size: 8)
        let first = NSPasteboardItem()
        first.setDataProvider(big, forTypes: [.png])
        first.setString("plain", forType: .string)
        let second = NSPasteboardItem()
        second.setDataProvider(after, forTypes: [.tiff])
        pasteboard.writeObjects([first, second])

        _ = PasteboardSnapshot.capture(from: pasteboard, byteBudget: 128)
        #expect(after.requests.isEmpty)
    }
}
