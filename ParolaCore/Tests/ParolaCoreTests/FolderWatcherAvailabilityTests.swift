import Foundation
import os
import Testing
@testable import ParolaCore

@Suite("FolderWatcher when the watched folder goes away", .tags(.fileSystem))
struct FolderWatcherAvailabilityTests {
    private typealias Fixture = WatchedFolderFixture

    private final class States: Sendable {
        private let storage = OSAllocatedUnfairLock<[FolderWatcher.State]>(initialState: [])
        func append(_ state: FolderWatcher.State) { storage.withLock { $0.append(state) } }
        var all: [FolderWatcher.State] { storage.withLock { $0 } }
    }

    private func makeWatcher(_ folder: URL, clock: FixedClock, states: States, collected: CollectedURLs) -> FolderWatcher {
        let options = FolderWatcher.Options(recursive: true, settledInterval: .milliseconds(50), clock: clock, scheduler: ManualScheduler())
        return FolderWatcher(
            folderURL: folder,
            options: options,
            onStateChange: { states.append($0) },
            onNewMediaFile: { collected.append($0) }
        )
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test("renaming the watched folder is reported as lost, and a watcher at the new name picks up from it")
    func renamedRootIsLost() async throws {
        let parent = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clock = FixedClock(start: Date())
        try Fixture.writeSettled(folder.appendingPathComponent("kept.m4a"), clock: clock)

        let states = States()
        let collected = CollectedURLs()
        let watcher = makeWatcher(folder, clock: clock, states: states, collected: collected)
        await watcher.start()
        #expect(await watcher.state == .watching)

        let renamed = parent.appendingPathComponent("Recordings")
        try FileManager.default.moveItem(at: folder, to: renamed)
        let watcherLostAccess = await waitUntil { await watcher.state == .lost }
        #expect(watcherLostAccess)
        #expect(states.all == [.lost])
        let saved = try #require(await watcher.baseline())
        #expect(saved.entries.map(\.path) == ["kept.m4a"])

        let scheduler = ManualScheduler()
        let options = FolderWatcher.Options(settledInterval: .milliseconds(50), clock: clock, scheduler: scheduler)
        let resumed = FolderWatcher(folderURL: renamed, options: options) { collected.append($0) }
        try Fixture.writeSettled(renamed.appendingPathComponent("new.wav"), clock: clock)
        await resumed.start(baseline: saved)
        try await scheduler.advance(ticks: 3)
        await resumed.stop()
        await watcher.stop()
        #expect(collected.snapshot().map(\.lastPathComponent) == ["new.wav"])
    }

    @Test("deleting the watched folder is reported as lost")
    func deletedRootIsLost() async throws {
        let parent = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clock = FixedClock(start: Date())
        try Fixture.writeSettled(folder.appendingPathComponent("gone.m4a"), clock: clock)

        let states = States()
        let watcher = makeWatcher(folder, clock: clock, states: states, collected: CollectedURLs())
        await watcher.start()
        try FileManager.default.removeItem(at: folder)

        let watcherLostAccess = await waitUntil { await watcher.state == .lost }
        #expect(watcherLostAccess)
        #expect(states.all == [.lost])
        await watcher.stop()
        #expect(await watcher.state == .idle)
    }

    @Test("a folder that can't be opened leaves the watcher unavailable, without a callback")
    func missingFolderIsUnavailable() async throws {
        let parent = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let states = States()
        let watcher = makeWatcher(
            parent.appendingPathComponent("Not There"), clock: FixedClock(start: Date()), states: states, collected: CollectedURLs()
        )
        await watcher.start()

        #expect(await watcher.state == .unavailable)
        #expect(states.all.isEmpty)
    }

    @Test("an unmount is told apart from a rename or a delete")
    func rootEventsAreSorted() {
        #expect(FolderWatcher.event(for: [.revoke], at: "/Volumes/Card") == .rootUnmounted)
        #expect(FolderWatcher.event(for: [.revoke, .delete], at: "/Volumes/Card") == .rootUnmounted)
        #expect(FolderWatcher.event(for: [.rename], at: "/Inbox") == .rootLost)
        #expect(FolderWatcher.event(for: [.delete], at: "/Inbox") == .rootLost)
        #expect(FolderWatcher.event(for: [.write], at: "/Inbox") == .changed("/Inbox"))
    }

    @Test("an unmounted folder stops its watch, says so, and keeps what it knew")
    func unmountedRootKeepsItsBaseline() async throws {
        let folder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = FixedClock(start: Date())
        try Fixture.writeSettled(folder.appendingPathComponent("kept.m4a"), clock: clock)
        let states = States()
        let watcher = makeWatcher(folder, clock: clock, states: states, collected: CollectedURLs())
        await watcher.start()

        await watcher.lose(.unmounted)
        #expect(await watcher.state == .unmounted)
        #expect(states.all == [.unmounted])
        #expect(await watcher.baseline()?.entries.map(\.path) == ["kept.m4a"])
    }
}
