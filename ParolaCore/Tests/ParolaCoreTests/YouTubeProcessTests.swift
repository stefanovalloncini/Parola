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

/// Limits for runs on a `TestClock`, which moves only when a test advances it.
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

/// The pid a fake wrote to `file`, or nil, with an issue, when it never wrote one.
private func childPID(in file: URL, sourceLocation: SourceLocation = #_sourceLocation) async -> Int32? {
    var pid: Int32?
    await pollUntil("the child to write its pid", sourceLocation: sourceLocation) {
        pid = (try? String(contentsOf: file, encoding: .utf8)).flatMap {
            Int32($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return pid != nil
    }
    return pid
}

private func expectEnded(_ pid: Int32?, sourceLocation: SourceLocation = #_sourceLocation) async {
    guard let pid else { return }
    await pollUntil("pid \(pid) to be gone", sourceLocation: sourceLocation) { !isAlive(pid) }
}

/// Points where a fake yt-dlp waits for the test, so the test clock moves only between the lines it chooses.
private struct Steps {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("parola-steps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Shell that holds the script until `open(step)`; `step` may be a shell expression such as `$i`.
    func hold(_ step: String) -> String {
        "until [ -e '\(folder.path)/go'\"\(step)\" ]; do sleep 0.05; done"
    }

    func open(_ step: Int) {
        FileManager.default.createFile(atPath: folder.appendingPathComponent("go\(step)").path, contents: nil)
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// A download on a test clock nobody advances, so no limit can end it; nil, with an issue, if it never finishes.
private func fetched(
    _ source: YouTubeAudioSource,
    sourceLocation: SourceLocation = #_sourceLocation,
    progress: @escaping @Sendable (LinkFetchEvent) -> Void = { _ in }
) async throws -> FetchedMedia? {
    try await GuardedTask { try await source.fetch(progress: progress) }
        .value("the download to finish", sourceLocation: sourceLocation)
}

private func expectCancelled<T>(_ run: GuardedTask<T>, sourceLocation: SourceLocation = #_sourceLocation) async {
    do {
        _ = try await run.value("the cancelled run to return", sourceLocation: sourceLocation)
        Issue.record("expected the run to be cancelled", sourceLocation: sourceLocation)
    } catch is CancellationError {
    } catch {
        Issue.record("expected a cancellation, got \(error)", sourceLocation: sourceLocation)
    }
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
        let clock = TestClock()
        let run = GuardedTask {
            try await YtDlpRunner.run(
                ytDlpPath: "/bin/sh", arguments: ["-c", "echo one; echo two >&2; exit 3"], run: .download,
                watch: .wallClock(seconds: 30), clock: clock
            )
        }
        let output = try await run.value("the run to exit on its own")
        #expect(output?.status == 3)
        #expect(output?.stdout == ["one"])
        #expect(output?.stderr == "two")
    }

    @Test("a run past its wall clock is ended and fails as a timeout")
    func wallClockOverrun() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("parola-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let clock = TestClock()
        let run = GuardedTask {
            try await YtDlpRunner.run(
                ytDlpPath: "/bin/sh", arguments: ["-c", "echo $$ > '\(pidFile.path)'; exec sleep 30"],
                run: .download, watch: .wallClock(seconds: 3), clock: clock
            )
        }
        let pid = await childPID(in: pidFile)
        await clock.waitForSleeper()
        clock.advance(by: .seconds(3))

        let failure = await linkFailure { _ = try await run.value("the run to end at its wall clock") }
        #expect(failure?.reason == .timedOut(seconds: 3))
        await expectEnded(pid)
    }

    @Test("output well past a pipe's buffer is read as it comes, without blocking the producer")
    func largeOutput() async throws {
        let clock = TestClock()
        let run = GuardedTask {
            try await YtDlpRunner.run(
                ytDlpPath: "/bin/sh", arguments: ["-c", "yes hello | head -n 20000"], run: .download,
                watch: .wallClock(seconds: 30), clock: clock
            )
        }
        let output = try await run.value("the run to print everything and exit")
        #expect(output?.stdout.count == 20000)
        #expect(output?.status == 0)
    }

    @Test("a download that keeps printing progress runs past the quiet limit")
    func progressKeepsTheRunAlive() async throws {
        let steps = try Steps()
        defer { steps.remove() }
        let fake = try fakeYtDlp("""
            for i in 1 2 3 4; do echo "[PAROLA_P] $((i * 100)) 400"; \(steps.hold("$i")); done
            echo "[PAROLA_FILE] /tmp/audio.m4a"
            """)
        defer { try? FileManager.default.removeItem(at: fake) }
        let clock = TestClock()
        let seen = Awaitable<[YtDlpLine]>([])
        let run = GuardedTask {
            try await YtDlpRunner.run(
                ytDlpPath: fake.path, arguments: [], run: .download, watch: .progress(tight(quiet: .seconds(3))), clock: clock
            ) { line in seen.update { $0.append(line) } }
        }

        for step in 1...4 {
            await seen.wait(until: { $0.count >= step }, "progress line \(step)")
            clock.advance(by: .seconds(2))
            steps.open(step)
        }
        let output = try await run.value("the download to finish")

        #expect(output?.status == 0)
        #expect(output?.filePath == "/tmp/audio.m4a")
        #expect(output?.stdout.isEmpty == true)
    }

    @Test("a download that goes quiet is ended as stalled, however long it ran before")
    func quietDownloadStalls() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("parola-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let steps = try Steps()
        defer { steps.remove() }
        let fake = try fakeYtDlp("""
            echo $$ > '\(pidFile.path)'
            for i in 1 2 3 4 5; do echo "[PAROLA_P] $i 10"; \(steps.hold("$i")); done
            exec sleep 30
            """)
        defer { try? FileManager.default.removeItem(at: fake) }
        let clock = TestClock()
        let seen = Awaitable<[YtDlpLine]>([])
        let run = GuardedTask {
            try await YtDlpRunner.run(
                ytDlpPath: fake.path, arguments: [], run: .download, watch: .progress(tight(quiet: .seconds(3))), clock: clock
            ) { line in seen.update { $0.append(line) } }
        }
        let pid = await childPID(in: pidFile)

        for step in 1...5 {
            await seen.wait(until: { $0.count >= step }, "progress line \(step)")
            clock.advance(by: .seconds(2))
            steps.open(step)
        }
        clock.advance(by: .seconds(3))

        let failure = await linkFailure { _ = try await run.value("the quiet download to be ended") }
        #expect(failure?.reason == .stalled(seconds: 3))
        await expectEnded(pid)
    }

    @Test("a silent extraction longer than the quiet limit is still within the startup allowance")
    func silentStartupSurvives() async throws {
        let steps = try Steps()
        defer { steps.remove() }
        let fake = try fakeYtDlp("""
            \(steps.hold("1"))
            echo '[PAROLA_META] {"title": "Slow page", "duration": 12}'
            echo "[PAROLA_P] 10 10"
            echo "[PAROLA_FILE] /tmp/audio.m4a"
            """)
        defer { try? FileManager.default.removeItem(at: fake) }
        let clock = TestClock()
        let run = GuardedTask {
            try await YtDlpRunner.run(
                ytDlpPath: fake.path, arguments: [], run: .download,
                watch: .progress(tight(startup: .seconds(15), quiet: .seconds(3))), clock: clock
            )
        }

        await clock.waitForSleeper()
        clock.advance(by: .seconds(5))
        steps.open(1)
        let output = try await run.value("the download to finish after its silent start")

        #expect(output?.status == 0)
        #expect(output?.metadata?.title == "Slow page")
    }

    @Test("a run that never gets past extraction is ended once the startup allowance runs out")
    func silentStartupStalls() async throws {
        let fake = try fakeYtDlp("exec sleep 30")
        defer { try? FileManager.default.removeItem(at: fake) }
        let clock = TestClock()
        let run = GuardedTask {
            try await YtDlpRunner.run(
                ytDlpPath: fake.path, arguments: [], run: .download,
                watch: .progress(tight(startup: .seconds(3), quiet: .seconds(1))), clock: clock
            )
        }

        await clock.waitForSleeper()
        clock.advance(by: .seconds(3))

        let failure = await linkFailure { _ = try await run.value("the silent run to be ended") }
        #expect(failure?.reason == .stalled(seconds: 3))
    }

    @Test("post-processing runs on its own budget, not the quiet limit")
    func processingHasItsOwnBudget() async throws {
        let steps = try Steps()
        defer { steps.remove() }
        let fake = try fakeYtDlp("""
            echo '[PAROLA_META] {"title": "Clip", "duration": 12}'
            echo "[PAROLA_P] 10 10"
            echo "[PAROLA_PP] started ExtractAudio" >&2
            \(steps.hold("1"))
            echo "[PAROLA_FILE] /tmp/audio.m4a"
            """)
        defer { try? FileManager.default.removeItem(at: fake) }
        let clock = TestClock()
        let seen = Awaitable<[YtDlpLine]>([])
        let run = GuardedTask {
            try await YtDlpRunner.run(
                ytDlpPath: fake.path, arguments: [], run: .download,
                watch: .progress(tight(quiet: .seconds(3), processing: .seconds(15))), clock: clock
            ) { line in seen.update { $0.append(line) } }
        }

        await seen.wait(until: { $0.count >= 3 && $0.contains(.processing) }, "the metadata, progress and processing lines")
        clock.advance(by: .seconds(4))
        steps.open(1)
        let output = try await run.value("the download to finish after post-processing")

        #expect(output?.status == 0)
        #expect(output?.metadata?.title == "Clip")
    }

    @Test("post-processing that overruns its budget fails as a timeout")
    func processingOverrun() async throws {
        let fake = try fakeYtDlp("""
            echo "[PAROLA_P] 10 10"
            echo "[PAROLA_PP] started ExtractAudio" >&2
            exec sleep 30
            """)
        defer { try? FileManager.default.removeItem(at: fake) }
        let clock = TestClock()
        let seen = Awaitable<[YtDlpLine]>([])
        let run = GuardedTask {
            try await YtDlpRunner.run(
                ytDlpPath: fake.path, arguments: [], run: .download,
                watch: .progress(tight(quiet: .seconds(30), processing: .seconds(3))), clock: clock
            ) { line in seen.update { $0.append(line) } }
        }

        await seen.wait(until: { $0.count >= 2 && $0.contains(.processing) }, "the progress and processing lines")
        clock.advance(by: .seconds(3))

        let failure = await linkFailure { _ = try await run.value("the overrunning post-processing to be ended") }
        #expect(failure?.reason == .timedOut(seconds: 3))
    }

    @Test("cancelling a run ends the process")
    func cancelEndsTheProcess() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("parola-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let clock = TestClock()
        let run = GuardedTask {
            try await YtDlpRunner.run(
                ytDlpPath: "/bin/sh", arguments: ["-c", "echo $$ > '\(pidFile.path)'; exec sleep 30"],
                run: .download, watch: .progress(tight(quiet: .seconds(30))), clock: clock
            )
        }
        let pid = await childPID(in: pidFile)
        run.cancel()

        await expectCancelled(run)
        await expectEnded(pid)
    }

    @Test("a run and its children that ignore SIGTERM are killed as a group")
    func stubbornGroupIsKilled() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("parola-stubborn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let childPid = scratch.appendingPathComponent("child")
        let fake = try fakeYtDlp("""
            trap '' TERM
            sleep 30 &
            echo $! > '\(childPid.path)'
            echo "[PAROLA_P] 1 10"
            while true; do sleep 1; done
            """)
        defer { try? FileManager.default.removeItem(at: fake) }
        let clock = TestClock()
        let seen = Awaitable<[YtDlpLine]>([])
        let run = GuardedTask {
            try await YtDlpRunner.run(
                ytDlpPath: fake.path, arguments: [], run: .download,
                watch: .progress(tight(quiet: .seconds(1))), clock: clock
            ) { line in seen.update { $0.append(line) } }
        }
        let pid = await childPID(in: childPid)
        await seen.wait(until: { !$0.isEmpty }, "the progress line")
        clock.advance(by: .seconds(1))

        let failure = await linkFailure { _ = try await run.value("the stalled group to be ended") }
        #expect(failure?.reason == .stalled(seconds: 1))
        await expectEnded(pid)
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

    private static func source(_ fake: URL) throws -> YouTubeAudioSource {
        try YouTubeAudioSource(url: link, features: .all, ytDlpPath: fake.path, limits: tight(), clock: TestClock())
    }

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
        let source = try Self.source(fake)

        let download = try await fetched(source) { events.append($0) }
        let media = try #require(download)
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
        let source = try Self.source(fake)

        let download = try await fetched(source)
        let media = try #require(download)

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
        let source = try Self.source(fake)

        let failure = await linkFailure { _ = try await fetched(source) }

        #expect(failure?.reason == .unavailable(.removed))
        #expect(!FileManager.default.fileExists(atPath: source.workingDir.path))
    }

    @Test("a cancelled download ends yt-dlp and leaves no folder behind")
    func cancelledDownloadCleansUp() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("parola-pid-\(UUID().uuidString)")
        let fake = try fakeYtDlp(Self.writesAudio + "\necho $$ > '\(pidFile.path)'\nexec sleep 30")
        defer { try? FileManager.default.removeItem(at: fake) }
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let source = try Self.source(fake)

        let download = GuardedTask { try await source.fetch() }
        let pid = await childPID(in: pidFile)
        download.cancel()

        await expectCancelled(download)
        await expectEnded(pid)
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

    @Test("no progress is delivered after the processing event, however the two pipes interleave")
    func progressNeverFollowsProcessing() async throws {
        let fake = try fakeYtDlp("""
            while [ $# -gt 0 ]; do
              [ "$1" = "-o" ] && out="$2"
              shift
            done
            file=$(printf '%s' "$out" | sed 's/%(ext)s/m4a/')
            i=0
            while [ $i -lt 200 ]; do
              echo "[PAROLA_P] $i 200"
              [ $i -eq 100 ] && echo "[PAROLA_PP] started ExtractAudio" >&2
              i=$((i + 1))
            done
            printf 'audio' > "$file"
            echo "[PAROLA_FILE] $file"
            """)
        defer { try? FileManager.default.removeItem(at: fake) }

        for _ in 0..<5 {
            let events = EventLog()
            let source = try Self.source(fake)
            let download = try await fetched(source) { events.append($0) }
            let media = try #require(download)
            media.discard()

            let delivered = events.all
            let processing = try #require(delivered.firstIndex(of: .processing))
            #expect(!delivered[(processing + 1)...].contains { if case .downloading = $0 { true } else { false } })
        }
    }

    @Test("a download that ends without a file fails as no audio")
    func noFileIsNoAudio() async throws {
        let fake = try fakeYtDlp("echo '[PAROLA_P] 1 1'")
        defer { try? FileManager.default.removeItem(at: fake) }
        let source = try Self.source(fake)

        let failure = await linkFailure { _ = try await fetched(source) }
        #expect(failure == LinkDownloadFailure(reason: .noAudio, site: "YouTube"))
    }
}

private final class EventLog: Sendable {
    private let events = OSAllocatedUnfairLock<[LinkFetchEvent]>(initialState: [])

    func append(_ event: LinkFetchEvent) { events.withLock { $0.append(event) } }
    var all: [LinkFetchEvent] { events.withLock { $0 } }
}
#endif
