import Foundation
import Testing

@Suite("parola diagnostics", .serialized, .enabled(if: parolaBinaryURL != nil))
struct DiagnosticsCommandProcessTests {
    private static let header = "Parola Diagnostics —"

    @Test func printsOnlyTheReportPath() throws {
        try withTemporaryHome { home, environment in
            let run = try runParola(["diagnostics"], environment: environment, currentDirectory: home)
            #expect(run.status == 0)

            let lines = run.stdout.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.isEmpty }
            #expect(lines.count == 1)
            let url = URL(fileURLWithPath: try #require(lines.first).description)
            #expect(url.deletingLastPathComponent().resolvingSymlinksInPath()
                == home.resolvingSymlinksInPath())
            #expect(url.lastPathComponent.hasPrefix("Parola-Diagnostics-"))
            #expect(url.pathExtension == "txt")

            let report = try String(contentsOf: url, encoding: .utf8)
            #expect(report.hasPrefix(Self.header))
            #expect(run.stderr.contains("No diagnostics recorded."))
        }
    }

    @Test func stdoutPrintsTheReportAndWritesNoFile() throws {
        try withTemporaryHome { home, environment in
            let run = try runParola(["diagnostics", "--stdout"], environment: environment, currentDirectory: home)
            #expect(run.status == 0)
            #expect(run.stdout.hasPrefix(Self.header))

            let written = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
            #expect(!written.contains { $0.hasSuffix(".txt") })
        }
    }

    @Test func clearDeletesTheRecordedDiagnostics() throws {
        try withTemporaryHome { home, environment in
            let directory = diagnosticsDirectory(in: home)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let seeded = directory.appendingPathComponent("parola-\(Self.deadProcessID())-1000.jsonl")
            try #"{"schemaVersion":1,"ts":"2026-08-22T13:58:02.114Z","level":"error","#
                .appending(#""subsystem":"app.parola.core","category":"models","message":"download failed"}"#)
                .appending("\n")
                .write(to: seeded, atomically: true, encoding: .utf8)

            let run = try runParola(
                ["diagnostics", "--stdout", "--clear"],
                environment: environment,
                currentDirectory: home
            )
            #expect(run.status == 0)
            #expect(run.stdout.contains("download failed"))
            #expect(run.stderr.contains("Deleted 1 file"))
            #expect(diagnosticsFiles(in: home).isEmpty)
        }
    }

    @Test func clearSparesAFileALiveProcessIsWriting() throws {
        try withTemporaryHome { home, environment in
            let directory = diagnosticsDirectory(in: home)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let live = directory.appendingPathComponent("parola-\(getpid())-1000.jsonl")
            let dead = directory.appendingPathComponent("parola-\(Self.deadProcessID())-1000.jsonl")
            for file in [live, dead] { try "\n".write(to: file, atomically: true, encoding: .utf8) }

            let run = try runParola(
                ["diagnostics", "--stdout", "--clear"],
                environment: environment,
                currentDirectory: home
            )
            #expect(run.status == 0)
            #expect(run.stderr.contains("1 still in use."))
            #expect(FileManager.default.fileExists(atPath: live.path))
            #expect(!FileManager.default.fileExists(atPath: dead.path))
        }
    }

    /// A pid near the top of the range macOS hands out, checked to be nobody's, so the file it
    /// names is safe to treat as abandoned.
    private static func deadProcessID() -> pid_t {
        for candidate in stride(from: pid_t(99_990), through: pid_t(90_000), by: -1)
        where kill(candidate, 0) != 0 && errno == ESRCH {
            return candidate
        }
        return 99_999
    }
}
