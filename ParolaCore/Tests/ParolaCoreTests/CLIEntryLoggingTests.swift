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

    /// The CLI commands own the process's argument parsing and its sink, so they are pinned in
    /// source rather than run: `Record.run()` opens a microphone.
    @Test("record and transcribe log their entry after the sink is installed")
    func entrySites() throws {
        let record = try source("parola/Commands/Record")
        #expect(record.contains(
            #"CLIDiagnostics.installIfWanted(alwaysOn: true) ParolaLog.info( .cli, "record started from \(source)","#
        ))
        #expect(record.contains(#"model.map { [LogField.model: LogValue.safe(ModelToken($0))] } ?? [:]"#))

        let transcribe = try source("parola/Commands/Transcribe")
        #expect(transcribe.contains(
            #"CLIDiagnostics.installIfWanted(alwaysOn: false) ParolaLog.info(.cli, "transcribe started", [.count: .int(inputs.count)])"#
        ))
    }

    @Test("the stdio runner logs the EOF that shuts it down")
    func stdinEOFSite() throws {
        let runner = try source("ParolaMCP/StdioRunner")
        #expect(runner.contains(
            #"ParolaLog.notice(.cli, "stdin closed, shutting down") await dispatcher.cancelAll()"#
        ))
    }
}
