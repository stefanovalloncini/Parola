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
            let seeded = directory.appendingPathComponent("parola-1-1000.jsonl")
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
}
