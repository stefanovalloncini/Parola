import Foundation
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
