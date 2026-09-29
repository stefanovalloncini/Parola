import Foundation
import os
import Testing
@testable import ParolaCore

@Suite("FolderWatcher offers a file the app couldn't use again", .tags(.fileSystem))
struct FolderWatcherOfferAgainTests {
    private typealias Fixture = WatchedFolderFixture

    private final class MovingClock: FolderWatcherClock, Sendable {
        private let current: OSAllocatedUnfairLock<Date>
        init(_ start: Date) { current = OSAllocatedUnfairLock(initialState: start) }
        func now() -> Date { current.withLock { $0 } }
        func move(by seconds: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    private func makeWatcher(
        _ folder: URL, clock: MovingClock, scheduler: ManualScheduler, collected: CollectedURLs
    ) -> FolderWatcher {
        var options = FolderWatcher.Options(
            recursive: true, settledInterval: .milliseconds(50), clock: clock, scheduler: scheduler
        )
        options.observesFileSystem = false
        return FolderWatcher(folderURL: folder, options: options) { collected.append($0) }
    }

    private func append(_ bytes: Int, to url: URL, modified: Date) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: bytes))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    /// Starts a watcher and lets `name` arrive once.
    private func arrived(
        _ name: String, in folder: URL, clock: MovingClock, scheduler: ManualScheduler, collected: CollectedURLs
    ) async throws -> (FolderWatcher, URL) {
        let watcher = makeWatcher(folder, clock: clock, scheduler: scheduler, collected: collected)
        await watcher.start()
        let file = folder.appendingPathComponent(name)
        try Fixture.writeSettled(file, clock: FixedClock(start: clock.now()), bytes: 1000)
        await watcher.checkForNewFiles()
        try await scheduler.advance(ticks: 3)
        return (watcher, try #require(collected.snapshot().last))
    }

    @Test("a file handed back after a failed run arrives again when it changes, however long it waited")
    func handedBackFileArrivesAgainOnChange() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = MovingClock(Date())
        let collected = CollectedURLs()
        let scheduler = ManualScheduler()
        let (watcher, url) = try await arrived(
            "recorder.wav", in: folder, clock: clock, scheduler: scheduler, collected: collected
        )
        #expect(collected.snapshot().count == 1)

        clock.move(by: 3600)
        await watcher.offerAgainOnChange(url)
        try append(2000, to: url, modified: clock.now().addingTimeInterval(-2))
        try await scheduler.advanceAndWait()
        #expect(Fixture.names(await watcher.pendingPaths) == ["recorder.wav"])
        try await scheduler.advance(ticks: 3)
        await watcher.stop()

        #expect(collected.snapshot().map(\.lastPathComponent) == ["recorder.wav", "recorder.wav"])
    }

    @Test("without the hand-back, the same late change is not a new arrival")
    func lateChangeWithoutHandBackStaysQuiet() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = MovingClock(Date())
        let collected = CollectedURLs()
        let scheduler = ManualScheduler()
        let (watcher, url) = try await arrived(
            "recorder.wav", in: folder, clock: clock, scheduler: scheduler, collected: collected
        )

        clock.move(by: 3600)
        try append(2000, to: url, modified: clock.now().addingTimeInterval(-2))
        await watcher.checkForNewFiles()
        #expect(await watcher.pendingPaths.isEmpty)
        await watcher.stop()

        #expect(collected.snapshot().count == 1)
    }

    @Test("a file handed back that never changes is not offered again, and a path the watcher never saw changes nothing")
    func unchangedHandBackStaysQuiet() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = MovingClock(Date())
        let collected = CollectedURLs()
        let scheduler = ManualScheduler()
        let (watcher, url) = try await arrived(
            "recorder.wav", in: folder, clock: clock, scheduler: scheduler, collected: collected
        )
        let before = await watcher.baseline()

        await watcher.offerAgainOnChange(folder.appendingPathComponent("never-seen.wav"))
        #expect(await watcher.baseline() == before)
        await watcher.offerAgainOnChange(url)
        try await scheduler.advance(ticks: 5)
        await watcher.stop()

        #expect(collected.snapshot().count == 1)
    }
}
