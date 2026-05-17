import Foundation
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
            #expect(!FolderWatcher.isMediaFile(url))
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

        let inserted = Container<URL>()
        let options = FolderWatcher.Options(
            recursive: true,
            settledInterval: .milliseconds(50),
            clock: SystemFolderWatcherClock()
        )
        let watcher = FolderWatcher(folderURL: tempDir, options: options) { url in
            Task { await inserted.append(url) }
        }
        await watcher.start()

        let nestedFile = subdir.appendingPathComponent("clip.wav")
        try Data(count: 1024).write(to: nestedFile)
        // Wait so the file's mtime is older than the settled cutoff.
        try await Task.sleep(for: .milliseconds(150))
        await watcher.checkForNewFiles()
        try await Task.sleep(for: .milliseconds(250))
        await watcher.stop()
        let captured = await inserted.snapshot()
        #expect(captured.contains(where: { $0.lastPathComponent == "clip.wav" }))
    }

    @Test("settled detection skips files still growing")
    func settledDetectionWaitsForStableSize() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inserted = Container<URL>()
        let options = FolderWatcher.Options(
            recursive: false,
            settledInterval: .milliseconds(200),
            clock: SystemFolderWatcherClock()
        )
        let watcher = FolderWatcher(folderURL: tempDir, options: options) { url in
            Task { await inserted.append(url) }
        }
        await watcher.start()

        let partial = tempDir.appendingPathComponent("growing.mp3")
        try Data(count: 256).write(to: partial)
        await watcher.checkForNewFiles()
        // Keep mutating so each settled tick sees an updated mtime/size.
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(150))
            try Data(count: 256 * (1 + Int.random(in: 1...4))).write(to: partial)
        }
        let afterChurn = await inserted.snapshot()
        #expect(afterChurn.isEmpty, "still-growing file should not have been emitted")
        // Stop mutating; the file is now stable. Wait for the settled interval to elapse.
        try await Task.sleep(for: .milliseconds(500))
        await watcher.checkForNewFiles()
        try await Task.sleep(for: .milliseconds(500))
        await watcher.stop()
        let final = await inserted.snapshot()
        #expect(final.contains(where: { $0.lastPathComponent == "growing.mp3" }))
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-folderwatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitForFolderEvent() async {
        try? await Task.sleep(for: .milliseconds(40))
    }
}

actor Container<T: Sendable> {
    private var items: [T] = []
    func append(_ item: T) { items.append(item) }
    func snapshot() -> [T] { items }
}

struct FixedClock: FolderWatcherClock {
    let start: Date
    func now() -> Date { start }
}

