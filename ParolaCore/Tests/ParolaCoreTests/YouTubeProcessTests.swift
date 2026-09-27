#if os(macOS)
import Foundation
import os
import Testing
@testable import ParolaCore

private func fakeYtDlp(_ body: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("parola-fake-yt-dlp-\(UUID().uuidString)")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

/// A freshly written script can take a second or two to start under a loaded test run, so no limit here is shorter than three.
private func tight(
    startup: Duration = .seconds(10), quiet: Duration = .seconds(5), processing: Duration = .seconds(5)
) -> YtDlpRunner.ProgressLimits {
    var limits = YtDlpRunner.ProgressLimits()
    limits.startup = startup
    limits.quiet = quiet
    limits.processingFloor = processing
    limits.processingUnknownLength = processing
    return limits
}

private func isAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0
}

private func linkFailure(_ body: () async throws -> Void) async -> LinkDownloadFailure? {
    do {
        try await body()
    } catch ParolaError.linkDownloadFailed(let failure) {
        return failure
    } catch {
        Issue.record("expected a link download failure, got \(error)")
    }
    return nil
}

@Suite("yt-dlp runner", .timeLimit(.minutes(1)))
struct YouTubeProcessTests {
    @Test("a run that exits on its own comes back with its status and its lines")
    func waitsForNaturalExit() async throws {
        let output = try await YtDlpRunner.run(
            ytDlpPath: "/bin/sh", arguments: ["-c", "echo one; echo two >&2; exit 3"], run: .download, watch: .wallClock(seconds: 30)
        )
        #expect(output.status == 3)
        #expect(output.stdout == ["one"])
        #expect(output.stderr == "two")
    }

    @Test("a run past its wall clock is ended and fails as a timeout")
    func wallClockOverrun() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("parola-pid-\(UUID().uuidString)")
        do {
            _ = try await YtDlpRunner.run(
                ytDlpPath: "/bin/sh", arguments: ["-c", "echo $$ > '\(pidFile.path)'; exec sleep 30"],
                run: .download, watch: .wallClock(seconds: 3)
            )
            Issue.record("expected the run to time out")
        } catch ParolaError.linkDownloadFailed(let failure) {
            #expect(failure.reason == .timedOut(seconds: 3))
        }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(!isAlive(pid))
    }

    @Test("output well past a pipe's buffer is read as it comes, without blocking the producer")
    func largeOutput() async throws {
        let output = try await YtDlpRunner.run(
            ytDlpPath: "/bin/sh", arguments: ["-c", "yes hello | head -n 20000"], run: .download, watch: .wallClock(seconds: 30)
        )
        #expect(output.stdout.count == 20000)
        #expect(output.status == 0)
    }

    @Test("a download that keeps printing progress runs past the quiet limit")
    func progressKeepsTheRunAlive() async throws {
        let fake = try fakeYtDlp("""
            for i in 1 2 3 4 5 6 7 8; do echo "[PAROLA_P] $((i * 100)) 800"; sleep 0.5; done
            echo "[PAROLA_FILE] /tmp/audio.m4a"
            """)
        defer { try? FileManager.default.removeItem(at: fake) }

        let output = try await YtDlpRunner.run(
            ytDlpPath: fake.path, arguments: [], run: .download, watch: .progress(tight(quiet: .seconds(3)))
        )

        #expect(output.status == 0)
        #expect(output.filePath == "/tmp/audio.m4a")
        #expect(output.stdout.isEmpty)
    }

    @Test("a download that goes quiet is ended as stalled, however long it ran before")
    func quietDownloadStalls() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("parola-pid-\(UUID().uuidString)")
        let fake = try fakeYtDlp("""
            echo $$ > '\(pidFile.path)'
            for i in 1 2 3 4 5; do echo "[PAROLA_P] $i 10"; sleep 0.5; done
            exec sleep 30
            """)
        defer { try? FileManager.default.removeItem(at: fake) }

        do {
            _ = try await YtDlpRunner.run(
                ytDlpPath: fake.path, arguments: [], run: .download, watch: .progress(tight(quiet: .seconds(3)))
            )
            Issue.record("expected the stall to end the run")
        } catch ParolaError.linkDownloadFailed(let failure) {
            #expect(failure.reason == .stalled(seconds: 3))
        }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(!isAlive(pid))
    }

    @Test("a silent extraction longer than the quiet limit is still within the startup allowance")
    func silentStartupSurvives() async throws {
        let fake = try fakeYtDlp("""
            sleep 5
            echo '[PAROLA_META] {"title": "Slow page", "duration": 12}'
            echo "[PAROLA_P] 10 10"
            echo "[PAROLA_FILE] /tmp/audio.m4a"
            """)
        defer { try? FileManager.default.removeItem(at: fake) }

        let output = try await YtDlpRunner.run(
            ytDlpPath: fake.path, arguments: [], run: .download,
            watch: .progress(tight(startup: .seconds(15), quiet: .seconds(3)))
        )

        #expect(output.status == 0)
        #expect(output.metadata?.title == "Slow page")
    }

    @Test("a run that never gets past extraction is ended once the startup allowance runs out")
    func silentStartupStalls() async throws {
        let fake = try fakeYtDlp("exec sleep 30")
        defer { try? FileManager.default.removeItem(at: fake) }

        let failure = await linkFailure {
            _ = try await YtDlpRunner.run(
                ytDlpPath: fake.path, arguments: [], run: .download,
                watch: .progress(tight(startup: .seconds(3), quiet: .seconds(1)))
            )
        }
        #expect(failure?.reason == .stalled(seconds: 3))
    }

    @Test("post-processing runs on its own budget, not the quiet limit")
    func processingHasItsOwnBudget() async throws {
        let fake = try fakeYtDlp("""
            echo '[PAROLA_META] {"title": "Clip", "duration": 12}'
            echo "[PAROLA_P] 10 10"
            echo "[PAROLA_PP] started ExtractAudio" >&2
            sleep 4
            echo "[PAROLA_FILE] /tmp/audio.m4a"
            """)
        defer { try? FileManager.default.removeItem(at: fake) }

        let output = try await YtDlpRunner.run(
            ytDlpPath: fake.path, arguments: [], run: .download,
            watch: .progress(tight(quiet: .seconds(3), processing: .seconds(15)))
        )

        #expect(output.status == 0)
        #expect(output.metadata?.title == "Clip")
    }

    @Test("post-processing that overruns its budget fails as a timeout")
    func processingOverrun() async throws {
        let fake = try fakeYtDlp("""
            echo "[PAROLA_P] 10 10"
            echo "[PAROLA_PP] started ExtractAudio" >&2
            exec sleep 30
            """)
        defer { try? FileManager.default.removeItem(at: fake) }

        let failure = await linkFailure {
            _ = try await YtDlpRunner.run(
                ytDlpPath: fake.path, arguments: [], run: .download,
                watch: .progress(tight(quiet: .seconds(30), processing: .seconds(3)))
            )
        }
        #expect(failure?.reason == .timedOut(seconds: 3))
    }

    @Test("cancelling a run ends the process")
    func cancelEndsTheProcess() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("parola-pid-\(UUID().uuidString)")
        let run = Task {
            try await YtDlpRunner.run(
                ytDlpPath: "/bin/sh", arguments: ["-c", "echo $$ > '\(pidFile.path)'; exec sleep 30"],
                run: .download, watch: .progress(tight(quiet: .seconds(30)))
            )
        }
        while !FileManager.default.fileExists(atPath: pidFile.path) { try await Task.sleep(for: .milliseconds(20)) }
        run.cancel()

        await #expect(throws: CancellationError.self) { _ = try await run.value }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(!isAlive(pid))
    }

    @Test("a binary that can't launch fails as a tool that didn't start")
    func launchFailure() async {
        let failure = await linkFailure {
            _ = try await YtDlpRunner.run(
                ytDlpPath: "/nonexistent/yt-dlp", arguments: [], run: .download, watch: .wallClock(seconds: 5)
            )
        }
        #expect(failure?.reason == .toolFailedToStart)
    }
}

@Suite("yt-dlp link download")
struct YouTubeAudioDownloadTests {
    private static let link = URL(string: "https://youtu.be/dQw4w9WgXcQ")!

    @Test("the audio download remuxes the m4a stream and prints what Parola reads")
    func arguments() {
        let arguments = YouTubeAudioSource.arguments(url: Self.link, outputTemplate: "/tmp/x/audio.%(ext)s")

        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
        }
        #expect(value(after: "-f") == "bestaudio[ext=m4a]/bestaudio/best")
        #expect(value(after: "--downloader") == "native")
        #expect(value(after: "--audio-format") == "m4a")
        #expect(value(after: "--socket-timeout") == "30")
        #expect(value(after: "-o") == "/tmp/x/audio.%(ext)s")
        #expect(arguments.contains("--progress"))
        #expect(arguments.contains("--newline"))
        #expect(arguments.contains(YtDlpLine.progressTemplate))
        #expect(arguments.contains(YtDlpLine.processingTemplate))
        #expect(arguments.contains(YtDlpLine.metadataTemplate))
        #expect(arguments.contains(YtDlpLine.fileTemplate))
        #expect(!arguments.contains("--no-warnings"))
        #expect(arguments.last == Self.link.absoluteString)
    }

    @Test("Parola's marked lines parse, and anything else is left to yt-dlp's own output", arguments: [
        ("[PAROLA_P] 2048 8192", YtDlpLine.downloaded(bytes: 2048, total: 8192)),
        ("[PAROLA_P] 2048 8192.5\r", YtDlpLine.downloaded(bytes: 2048, total: 8192.5)),
        ("[PAROLA_P] 2048 NA", YtDlpLine.downloaded(bytes: 2048, total: nil)),
        ("[PAROLA_PP] started ExtractAudio", YtDlpLine.processing),
        ("[PAROLA_FILE] /tmp/parola-yt-1/audio.m4a", YtDlpLine.file("/tmp/parola-yt-1/audio.m4a")),
        (#"[PAROLA_META] {"title": "Caffè\t\"x\"", "webpage_url": "https://www.youtube.com/watch?v=abc", "id": "abc", "duration": 125.0}"#,
         YtDlpLine.metadata(LinkMetadata(
            title: "Caffè\t\"x\"", webpageURL: URL(string: "https://www.youtube.com/watch?v=abc"), id: "abc", duration: 125
         ))),
        (#"[PAROLA_META] {"title": "x", "id": "abc"}"#, YtDlpLine.metadata(LinkMetadata(title: "x", id: "abc"))),
    ])
    func parsesMarkedLines(raw: String, expected: YtDlpLine) {
        #expect(YtDlpLine(raw) == expected)
    }

    @Test("unmarked or broken lines aren't Parola's", arguments: [
        "[download] Destination: audio.webm", "[PAROLA_P] NA NA", "[PAROLA_FILE] ", "WARNING: [youtube] something",
    ])
    func ignoresOtherLines(raw: String) {
        #expect(YtDlpLine(raw) == nil)
    }

    @Test("progress becomes a fraction only when the size is known")
    func progressFraction() {
        #expect(YtDlpLine.downloaded(bytes: 50, total: 200).event == .downloading(fraction: 0.25))
        #expect(YtDlpLine.downloaded(bytes: 50, total: nil).event == .downloading(fraction: nil))
        #expect(YtDlpLine.downloaded(bytes: 300, total: 200).event == .downloading(fraction: 1))
        #expect(YtDlpLine.file("/tmp/a.m4a").event == nil)
    }

    @Test("the post-processing budget grows with the video's length")
    func processingBudget() {
        let limits = YtDlpRunner.ProgressLimits()
        #expect(limits.processing(mediaSeconds: 60) == .seconds(120))
        #expect(limits.processing(mediaSeconds: 7200) == .seconds(1800))
        #expect(limits.processing(mediaSeconds: nil) == .seconds(600))
    }

    /// stdout and stderr are read apart, so only the contract is pinned: progress never runs backwards past processing.
    @Test("a download through a fake yt-dlp reports its progress in order and returns the file with the video's details")
    func downloadReportsProgress() async throws {
        let fake = try fakeYtDlp("""
            while [ $# -gt 0 ]; do
              [ "$1" = "-o" ] && out="$2"
              shift
            done
            file=$(printf '%s' "$out" | sed 's/%(ext)s/m4a/')
            echo '[PAROLA_META] {"title": "A talk", "webpage_url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "id": "dQw4w9WgXcQ", "duration": 90}'
            echo "[PAROLA_P] 0 400"
            echo "[PAROLA_P] 200 400"
            echo "[PAROLA_P] 400 400"
            sleep 1
            echo "[PAROLA_PP] started ExtractAudio" >&2
            printf 'audio' > "$file"
            echo "[PAROLA_FILE] $file"
            """)
        defer { try? FileManager.default.removeItem(at: fake) }
        let events = EventLog()
        let source = try YouTubeAudioSource(url: Self.link, features: .all, ytDlpPath: fake.path, limits: tight())

        let media = try await source.fetch { events.append($0) }
        defer { try? FileManager.default.removeItem(at: media.fileURL.deletingLastPathComponent()) }

        #expect(media.fileURL.lastPathComponent == "audio.m4a")
        #expect(FileManager.default.fileExists(atPath: media.fileURL.path))
        #expect(media.metadata.title == "A talk")
        #expect(media.metadata.webpageURL == URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        #expect(media.metadata.id == "dQw4w9WgXcQ")
        #expect(media.metadata.duration == 90)
        let delivered = events.all
        let fractions = delivered.compactMap { if case .downloading(let fraction) = $0 { fraction } else { nil } }
        let processing = try #require(delivered.firstIndex(of: .processing))
        #expect(delivered.filter { $0 != .processing }.first == .metadata(media.metadata))
        #expect(fractions == fractions.sorted() && Set(fractions).isSubset(of: [0, 0.5, 1]))
        #expect(!delivered[(processing + 1)...].contains { if case .downloading = $0 { true } else { false } })
        #expect(delivered.filter { $0 == .processing }.count == 1)
    }

    private static let writesAudio = """
        while [ $# -gt 0 ]; do
          [ "$1" = "-o" ] && out="$2"
          shift
        done
        file=$(printf '%s' "$out" | sed 's/%(ext)s/m4a/')
        printf 'audio' > "$file"
        """

    @Test("a finished download owns its folder until it's discarded")
    func finishedDownloadOwnsItsFolder() async throws {
        let fake = try fakeYtDlp(Self.writesAudio + "\necho \"[PAROLA_FILE] $file\"")
        defer { try? FileManager.default.removeItem(at: fake) }
        let source = try YouTubeAudioSource(url: Self.link, features: .all, ytDlpPath: fake.path, limits: tight())

        let media = try await source.fetch()

        #expect(media.workingDirectory == source.workingDir)
        #expect(media.fileURL.deletingLastPathComponent().path == source.workingDir.path)
        #expect(FileManager.default.fileExists(atPath: media.fileURL.path))
        media.discard()
        #expect(!FileManager.default.fileExists(atPath: source.workingDir.path))
    }

    @Test("a failed download leaves no folder behind")
    func failedDownloadCleansUp() async throws {
        let fake = try fakeYtDlp(Self.writesAudio + "\necho 'ERROR: [youtube] x: Video unavailable' >&2\nexit 1")
        defer { try? FileManager.default.removeItem(at: fake) }
        let source = try YouTubeAudioSource(url: Self.link, features: .all, ytDlpPath: fake.path, limits: tight())

        let failure = await linkFailure { _ = try await source.fetch() }

        #expect(failure?.reason == .unavailable(.removed))
        #expect(!FileManager.default.fileExists(atPath: source.workingDir.path))
    }

    @Test("a cancelled download ends yt-dlp and leaves no folder behind")
    func cancelledDownloadCleansUp() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("parola-pid-\(UUID().uuidString)")
        let fake = try fakeYtDlp(Self.writesAudio + "\necho $$ > '\(pidFile.path)'\nexec sleep 30")
        defer { try? FileManager.default.removeItem(at: fake) }
        let source = try YouTubeAudioSource(url: Self.link, features: .all, ytDlpPath: fake.path, limits: tight(quiet: .seconds(30)))

        let download = Task { try await source.fetch() }
        while !FileManager.default.fileExists(atPath: pidFile.path) { try await Task.sleep(for: .milliseconds(20)) }
        download.cancel()

        await #expect(throws: CancellationError.self) { _ = try await download.value }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(!isAlive(pid))
        #expect(!FileManager.default.fileExists(atPath: source.workingDir.path))
    }

    @Test("the launch sweep removes day-old download folders and nothing else")
    func sweepRemovesStaleFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parola-sweep-\(UUID().uuidString)")
        let stale = root.appendingPathComponent("\(LinkDownloadFolders.prefix)stale")
        let fresh = root.appendingPathComponent("\(LinkDownloadFolders.prefix)fresh")
        let unrelated = root.appendingPathComponent("parola-other")
        for folder in [stale, fresh, unrelated] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let twoDaysAgo = now.addingTimeInterval(-2 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: unrelated.path)

        #expect(LinkDownloadFolders.removeStale(in: root, now: now) == 1)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test("a download that ends without a file fails as no audio")
    func noFileIsNoAudio() async throws {
        let fake = try fakeYtDlp("echo '[PAROLA_P] 1 1'")
        defer { try? FileManager.default.removeItem(at: fake) }
        let source = try YouTubeAudioSource(url: Self.link, features: .all, ytDlpPath: fake.path, limits: tight())

        let failure = await linkFailure { _ = try await source.fetch() }
        #expect(failure == LinkDownloadFailure(reason: .noAudio, site: "YouTube"))
    }
}

private final class EventLog: Sendable {
    private let events = OSAllocatedUnfairLock<[LinkFetchEvent]>(initialState: [])

    func append(_ event: LinkFetchEvent) { events.withLock { $0.append(event) } }
    var all: [LinkFetchEvent] { events.withLock { $0 } }
}
#endif
