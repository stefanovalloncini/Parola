import Foundation
import Testing
@testable import ParolaCore

@Suite("FolderWatcher leaves Parola's own outputs alone", .tags(.fileSystem))
struct FolderWatcherOutputMarkerTests {
    private typealias Fixture = WatchedFolderFixture

    private func makeWatcher(
        _ folder: URL, clock: FixedClock, scheduler: ManualScheduler, collected: CollectedURLs
    ) -> FolderWatcher {
        var options = FolderWatcher.Options(
            recursive: true, settledInterval: .milliseconds(50), clock: clock, scheduler: scheduler
        )
        options.observesFileSystem = false
        return FolderWatcher(folderURL: folder, options: options) { collected.append($0) }
    }

    @Test("a video Parola marked as its own output is not emitted; an unmarked one is")
    func markedFileIsNotAnArrival() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        let collected = CollectedURLs()
        let scheduler = ManualScheduler()
        let watcher = makeWatcher(folder, clock: clock, scheduler: scheduler, collected: collected)
        await watcher.start()

        let burned = folder.appendingPathComponent("Talk (captioned).mp4")
        let recorded = folder.appendingPathComponent("Talk.mp4")
        try Fixture.writeSettled(burned, clock: clock)
        OutputMarker.mark(burned)
        try Fixture.writeSettled(recorded, clock: clock)
        await watcher.checkForNewFiles()
        try await scheduler.advance(ticks: 3)
        let baseline = try #require(await watcher.baseline())
        await watcher.stop()

        #expect(collected.snapshot().map(\.lastPathComponent) == ["Talk.mp4"])
        let entries = Dictionary(uniqueKeysWithValues: baseline.entries.map { ($0.path, $0) })
        #expect(entries["Talk (captioned).mp4"] != nil)
        #expect(entries["Talk (captioned).mp4"]?.emittedAt == nil)
        #expect(entries["Talk.mp4"]?.emittedAt == clock.start)
    }

    @Test("a marked file that grows later is still not an arrival")
    func markedFileStaysQuietWhenItChanges() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        let collected = CollectedURLs()
        let scheduler = ManualScheduler()
        let watcher = makeWatcher(folder, clock: clock, scheduler: scheduler, collected: collected)
        await watcher.start()

        let burned = folder.appendingPathComponent("clip (captioned).mov")
        try Fixture.writeSettled(burned, clock: clock)
        OutputMarker.mark(burned)
        await watcher.checkForNewFiles()
        try await scheduler.advance(ticks: 3)
        let handle = try FileHandle(forWritingTo: burned)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 512))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: clock.start.addingTimeInterval(-2)], ofItemAtPath: burned.path
        )
        await watcher.checkForNewFiles()
        #expect(await watcher.pendingPaths.isEmpty)
        await watcher.stop()

        #expect(collected.snapshot().isEmpty)
    }
}
