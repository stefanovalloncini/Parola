import Foundation
import Testing
@testable import ParolaCore

@Suite("CLI entry logging")
struct CLIEntryLoggingTests {
    private func source(_ path: String) throws -> String {
        let file = #filePath.replacingOccurrences(
            of: "ParolaCore/Tests/ParolaCoreTests/CLIEntryLoggingTests.swift",
            with: "ParolaCore/Sources/\(path).swift"
        )
        let text = try String(contentsOfFile: file, encoding: .utf8)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Pinned in source rather than run: `Record.run()` opens a microphone.
    @Test("record and transcribe gate before they log their entry")
    func entrySites() throws {
        let record = try source("parola/Commands/Record")
        #expect(record.contains(
            #"CLIDiagnostics.installIfWanted(alwaysOn: true) switch source {"#
        ))
        #expect(record.contains(
            #"} ParolaLog.info( .cli, "record started from \(source)","#
        ))
        #expect(record.contains(#"model.map { [LogField.model: LogValue.safe(ModelToken($0))] } ?? [:]"#))

        let transcribe = try source("parola/Commands/Transcribe")
        #expect(transcribe.contains(
            #"guard !inputs.isEmpty else { throw ValidationError("At least one input file is required.") }"#
                + #" ParolaLog.info(.cli, "transcribe started", [.count: .int(inputs.count)])"#
        ))
    }

    /// Record stays visible with `meetings` enabled; only the mic-source gate refuses.
    @Test(
        "the mic-source gate refuses record before it logs its entry",
        .enabled(if: parolaBinaryURL != nil)
    )
    func recordGateRefusesBeforeLogging() throws {
        try withTemporaryHome { home, environment in
            let plist = home.appendingPathComponent("gate.plist")
            try (["enabledFeatures": ["meetings", "batch"]] as NSDictionary).write(to: plist)
            var overrides = environment
            overrides["PAROLA_MANAGED_PLIST"] = plist.path
            let run = try runParola(["record"], environment: overrides, currentDirectory: home)

            #expect(run.status != 0)
            #expect(run.output.contains("disabled in this deployment"))
            let sinkText = diagnosticsFiles(in: home)
                .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                .joined()
            #expect(!sinkText.contains("record started from"))
        }
    }

    @Test("the stdio runner logs the EOF that shuts it down")
    func stdinEOFSite() throws {
        let runner = try source("ParolaMCP/StdioRunner")
        #expect(runner.contains(
            #"ParolaLog.notice(.cli, "stdin closed, shutting down") await dispatcher.cancelAll()"#
        ))
    }
}
