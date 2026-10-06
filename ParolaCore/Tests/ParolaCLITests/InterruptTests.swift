import Foundation
import os
import Testing
@testable import ParolaCore
@testable import parola

/// These send SIGINT to the test process itself, which only works while `untilInterrupted` holds the signal.
@Suite("CLI interrupt during a link download", .serialized, .timeLimit(.minutes(1)))
struct InterruptTests {
    private func handlesByDefault(_ signal: Int32) -> Bool {
        var current = sigaction()
        sigaction(signal, nil, &current)
        return current.__sigaction_u.__sa_handler == nil
    }

    @Test("a body that finishes first comes back, and Ctrl-C kills the process again afterwards")
    func finishedBodyRestoresSignals() async throws {
        let value = try await untilInterrupted { 42 }

        #expect(value == 42)
        #expect(handlesByDefault(SIGINT))
        #expect(handlesByDefault(SIGTERM))
    }

    @Test("a value the body still finishes with after Ctrl-C is handed back for cleanup")
    func lateValueIsAbandoned() async throws {
        let abandoned = OSAllocatedUnfairLock<[Int]>(initialState: [])

        await #expect(throws: Interrupted.self) {
            _ = try await untilInterrupted(abandoning: { value in abandoned.withLock { $0.append(value) } }) {
                kill(getpid(), SIGINT)
                usleep(300_000)
                return 7
            }
        }

        #expect(abandoned.withLock { $0 } == [7])
        #expect(handlesByDefault(SIGINT))
    }

    @Test("Ctrl-C during transcription cleans up first, then ends the process with 130")
    func cleanupRunsBeforeTheEnd() async throws {
        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
        let cleanup = InterruptCleanup({ calls.withLock { $0.append("cleanup") } }, ending: { status in
            calls.withLock { $0.append("end \(status)") }
        })

        kill(getpid(), SIGINT)
        let deadline = ContinuousClock.now + .seconds(5)
        while calls.withLock({ $0.count }) < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        cleanup.stop()

        #expect(calls.withLock { $0 } == ["cleanup", "end 130"])
    }

    @Test("during a live take the first Ctrl-C asks it to stop and a second ends the process with 130")
    func secondInterruptEndsTheTake() async throws {
        let (calls, record) = AsyncStream<String>.makeStream()
        let interrupts = StopThenInterrupt(stop: { record.yield("stop") }, ending: { status in record.yield("end \(status)") })
        defer { interrupts.end() }
        var heard = calls.makeAsyncIterator()
        #expect(!interrupts.wasInterrupted)

        kill(getpid(), SIGINT)
        #expect(await heard.next() == "stop")
        #expect(interrupts.wasInterrupted)

        kill(getpid(), SIGINT)
        #expect(await heard.next() == "end 130")
    }

    @Test("Ctrl-C during a download ends yt-dlp, removes its folder and reports the interrupt")
    func interruptEndsTheDownload() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("parola-cli-interrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let pidFile = scratch.appendingPathComponent("pid")
        let fake = scratch.appendingPathComponent("yt-dlp")
        try """
            #!/bin/sh
            [ "$1" = "--version" ] && exit 1
            while [ $# -gt 0 ]; do
              [ "$1" = "-o" ] && out="$2"
              shift
            done
            printf 'partial' > "$(printf '%s' "$out" | sed 's/%(ext)s/webm.part/')"
            echo $$ > '\(pidFile.path)'
            exec sleep 30
            """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        var limits = YtDlpRunner.ProgressLimits()
        limits.quiet = .seconds(30)
        let source = try YouTubeAudioSource(
            url: URL(string: "https://youtu.be/dQw4w9WgXcQ")!, features: .all, ytDlpPath: fake.path, limits: limits
        )

        let run = Task { try await untilInterrupted { try await source.fetch() } }
        while !FileManager.default.fileExists(atPath: pidFile.path) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(FileManager.default.fileExists(atPath: source.workingDir.path))
        kill(getpid(), SIGINT)

        await #expect(throws: Interrupted.self) { _ = try await run.value }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0)
        #expect(!FileManager.default.fileExists(atPath: source.workingDir.path))
        #expect(handlesByDefault(SIGINT))
    }
}
