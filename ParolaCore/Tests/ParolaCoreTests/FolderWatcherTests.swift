import Foundation
import os
import Testing
@testable import ParolaCore

@Suite("FolderWatcher media filter and lifecycle", .tags(.fileSystem))
struct FolderWatcherTests {
    @Test("audio extensions are recognized")
    func audio() {
        for ext in ["mp3", "wav", "m4a", "flac"] {
            let url = URL(fileURLWithPath: "/tmp/sample.\(ext)")
            #expect(FolderWatcher.isMediaFile(url))
        }
    }

    @Test("video extensions are recognized")
    func video() {
        for ext in ["mp4", "mov", "m4v"] {
            let url = URL(fileURLWithPath: "/tmp/sample.\(ext)")
            #expect(FolderWatcher.isMediaFile(url))
        }
    }

    @Test("non-media extensions are rejected")
    func nonMedia() {
        for ext in ["txt", "pdf", "jpg", "swift"] {
            let url = URL(fileURLWithPath: "/tmp/sample.\(ext)")
            #expect(FolderWatcher.isMediaFile(url) == false)
        }
    }

    @Test("extension match is case-insensitive")
    func caseInsensitive() {
        #expect(FolderWatcher.isMediaFile(URL(fileURLWithPath: "/tmp/x.MP3")))
        #expect(FolderWatcher.isMediaFile(URL(fileURLWithPath: "/tmp/x.Mov")))
    }

    @Test("recursive scan picks up files in subdirectories")
    func recursiveScanSeesSubdirs() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let subdir = tempDir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        let inserted = CollectedURLs()
        let scheduler = ManualScheduler()
        let clock = FixedClock(start: Date())
        let options = FolderWatcher.Options(
            recursive: true,
            settledInterval: .milliseconds(50),
            clock: clock,
            scheduler: scheduler
        )
        let watcher = FolderWatcher(folderURL: tempDir, options: options) { url in
            inserted.append(url)
        }
        await watcher.start()

        let nestedFile = subdir.appendingPathComponent("clip.wav")
        try WatchedFolderFixture.writeSettled(nestedFile, clock: clock)
        await watcher.checkForNewFiles()
        try await scheduler.advance(ticks: 3)
        await watcher.stop()

        let captured = inserted.snapshot()
        #expect(captured.contains(where: { $0.lastPathComponent == "clip.wav" }))
    }

    @Test("settled detection skips files still growing")
    func settledDetectionWaitsForStableSize() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inserted = CollectedURLs()
        let scheduler = ManualScheduler()
        let clock = FixedClock(start: Date())
        let options = FolderWatcher.Options(
            recursive: false,
            settledInterval: .milliseconds(200),
            clock: clock,
            scheduler: scheduler
        )
        let watcher = FolderWatcher(folderURL: tempDir, options: options) { url in
            inserted.append(url)
        }
        await watcher.start()

        let partial = tempDir.appendingPathComponent("growing.mp3")
        try Data(count: 256).write(to: partial)
        await watcher.checkForNewFiles()

        for chunk in 1...3 {
            try Data(count: 256 * (1 + chunk)).write(to: partial)
            try FileManager.default.setAttributes(
                [.modificationDate: clock.start],
                ofItemAtPath: partial.path
            )
            try await scheduler.advanceAndWait()
        }
        #expect(inserted.snapshot().isEmpty, "still-growing file should not have been emitted")

        try FileManager.default.setAttributes(
            [.modificationDate: clock.start.addingTimeInterval(-10)],
            ofItemAtPath: partial.path
        )
        await watcher.checkForNewFiles()
        try await scheduler.advance(ticks: 2)
        #expect(inserted.snapshot().isEmpty, "the date changed on the first of these checks")
        try await scheduler.advanceAndWait()
        await watcher.stop()

        let final = inserted.snapshot()
        #expect(final.contains(where: { $0.lastPathComponent == "growing.mp3" }))
    }

    @Test("a deleted-then-recreated file with the same name is detected again")
    func recreatedFileIsRedetected() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inserted = CollectedURLs()
        let scheduler = ManualScheduler()
        let clock = FixedClock(start: Date())
        let options = FolderWatcher.Options(
            recursive: false,
            settledInterval: .milliseconds(50),
            clock: clock,
            scheduler: scheduler
        )
        let watcher = FolderWatcher(folderURL: tempDir, options: options) { url in
            inserted.append(url)
        }
        await watcher.start()

        let file = tempDir.appendingPathComponent("clip.wav")
        func writeSettled() throws {
            try WatchedFolderFixture.writeSettled(file, clock: clock)
        }

        try writeSettled()
        await watcher.checkForNewFiles()
        try await scheduler.advance(ticks: 3)
        #expect(inserted.snapshot().count == 1)

        try FileManager.default.removeItem(at: file)
        await watcher.checkForNewFiles()  // the path is forgotten

        try writeSettled()  // recreate with the same name
        await watcher.checkForNewFiles()
        try await scheduler.advance(ticks: 3)
        await watcher.stop()

        #expect(inserted.snapshot().count == 2, "recreated same-name file must be detected again")
    }

    @Test("a media file present before start() is never emitted (existing files are ignored)")
    func existingFilesAtStartAreIgnored() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let clock = FixedClock(start: Date())
        let existing = tempDir.appendingPathComponent("already-here.wav")
        try writeSettled(existing, clock: clock)

        let inserted = CollectedURLs()
        let scheduler = ManualScheduler()
        let options = FolderWatcher.Options(
            recursive: false,
            settledInterval: .milliseconds(50),
            clock: clock,
            scheduler: scheduler
        )
        let watcher = FolderWatcher(folderURL: tempDir, options: options) { url in
            inserted.append(url)
        }
        await watcher.start()  // seeds knownFiles with already-here.wav

        // A genuinely new drop rides the same settle tick, so the test still drives processPending
        // (and would catch the pre-existing file if start() failed to seed it).
        let fresh = tempDir.appendingPathComponent("new-drop.wav")
        try writeSettled(fresh, clock: clock)
        await watcher.checkForNewFiles()
        try await scheduler.advance(ticks: 3)
        await watcher.stop()

        let captured = inserted.snapshot()
        #expect(captured.contains { $0.lastPathComponent == "new-drop.wav" })
        #expect(!captured.contains { $0.lastPathComponent == "already-here.wav" },
                "a file present before start() must never be transcribed")
    }

    @Test("non-media files dropped into the folder are not emitted")
    func nonMediaFilesAreNotEmitted() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inserted = CollectedURLs()
        let scheduler = ManualScheduler()
        let clock = FixedClock(start: Date())
        let options = FolderWatcher.Options(
            recursive: false,
            settledInterval: .milliseconds(50),
            clock: clock,
            scheduler: scheduler
        )
        let watcher = FolderWatcher(folderURL: tempDir, options: options) { url in
            inserted.append(url)
        }
        await watcher.start()

        try writeSettled(tempDir.appendingPathComponent("notes.txt"), clock: clock)
        try writeSettled(tempDir.appendingPathComponent("audio.wav"), clock: clock)
        await watcher.checkForNewFiles()
        try await scheduler.advance(ticks: 3)
        await watcher.stop()

        let captured = inserted.snapshot()
        #expect(captured.contains { $0.lastPathComponent == "audio.wav" })
        #expect(!captured.contains { $0.lastPathComponent == "notes.txt" })
    }

    @Test("a zero-byte media file is never emitted")
    func zeroByteMediaFileIsNotEmitted() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inserted = CollectedURLs()
        let scheduler = ManualScheduler()
        let clock = FixedClock(start: Date())
        let options = FolderWatcher.Options(
            recursive: false,
            settledInterval: .milliseconds(50),
            clock: clock,
            scheduler: scheduler
        )
        let watcher = FolderWatcher(folderURL: tempDir, options: options) { url in
            inserted.append(url)
        }
        await watcher.start()

        let empty = tempDir.appendingPathComponent("empty.wav")
        try Data(count: 0).write(to: empty)
        try FileManager.default.setAttributes(
            [.modificationDate: clock.start.addingTimeInterval(-10)],
            ofItemAtPath: empty.path
        )
        await watcher.checkForNewFiles()
        try await scheduler.advanceAndWait()  // stays pending (size 0), re-arms the settle tick
        #expect(inserted.snapshot().isEmpty, "a zero-byte file has nothing to transcribe")

        // Drain the re-armed tick so stop() isn't cancelling a parked scheduler continuation.
        try FileManager.default.removeItem(at: empty)
        try await scheduler.advanceAndWait()  // file gone → dropped from pending, no re-arm
        await watcher.stop()
        #expect(inserted.snapshot().isEmpty)
    }

    private func writeSettled(_ url: URL, clock: FixedClock) throws {
        try WatchedFolderFixture.writeSettled(url, clock: clock)
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-folderwatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
