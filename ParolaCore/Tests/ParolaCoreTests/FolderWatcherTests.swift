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
        try Data(count: 1024).write(to: nestedFile)
        try FileManager.default.setAttributes(
            [.modificationDate: clock.start.addingTimeInterval(-10)],
            ofItemAtPath: nestedFile.path
        )
        await watcher.checkForNewFiles()
        try await scheduler.advanceAndWait()
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
            try Data(count: 1024).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: clock.start.addingTimeInterval(-10)],
                ofItemAtPath: file.path
            )
        }

        try writeSettled()
        await watcher.checkForNewFiles()
        try await scheduler.advanceAndWait()
        #expect(inserted.snapshot().count == 1)

        try FileManager.default.removeItem(at: file)
        await watcher.checkForNewFiles()  // the path is forgotten

        try writeSettled()  // recreate with the same name
        await watcher.checkForNewFiles()
        try await scheduler.advanceAndWait()
        await watcher.stop()

        #expect(inserted.snapshot().count == 2, "recreated same-name file must be detected again")
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-folderwatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class CollectedURLs: Sendable {
    private let storage = OSAllocatedUnfairLock<[URL]>(initialState: [])
    func append(_ url: URL) {
        storage.withLock { $0.append(url) }
    }
    func snapshot() -> [URL] {
        storage.withLock { $0 }
    }
}

struct FixedClock: FolderWatcherClock {
    let start: Date
    func now() -> Date { start }
}

actor ManualScheduler: FolderWatcherScheduler {
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var done: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func runTick(after interval: Duration, _ body: @Sendable @escaping () async -> Void) async throws {
        await park()
        await body()
        await signalDone()
    }

    func advanceAndWait() async throws {
        if parked.isEmpty {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                arrivalWaiters.append(cont)
            }
        }
        let go = parked.removeFirst()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            done.append(cont)
            go.resume()
        }
    }

    private func park() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            parked.append(cont)
            if let waiter = arrivalWaiters.first {
                arrivalWaiters.removeFirst()
                waiter.resume()
            }
        }
    }

    private func signalDone() {
        guard !done.isEmpty else { return }
        done.removeFirst().resume()
    }
}
