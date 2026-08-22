import Foundation
import Testing
@testable import ParolaCore

@Suite("File diagnostics sink", .serialized)
struct FileDiagnosticsSinkTests {
    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-diag-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func record(_ level: LogLevel, _ text: StaticString) -> LogRecord {
        LogRecord(
            timestamp: Date(timeIntervalSince1970: 1_755_871_082),
            level: level, subsystem: "app.parola.core", category: .models,
            message: LogMessage(stringLiteral: text), fields: [:],
            file: "T.swift", line: 1
        )
    }

    @Test("an error flushes to disk without an explicit flush")
    func errorFlushesEagerly() throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir)
        sink.enqueue(record(.error, "boom"))
        let text = try String(contentsOf: sink.currentFileURL, encoding: .utf8)
        #expect(text.contains("boom"))
    }

    @Test("info records buffer until flushed")
    func infoBuffersUntilFlush() async throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir)
        sink.enqueue(record(.info, "buffered"))
        let before = (try? String(contentsOf: sink.currentFileURL, encoding: .utf8)) ?? ""
        #expect(before.contains("buffered") == false)
        await sink.flush()
        let after = try String(contentsOf: sink.currentFileURL, encoding: .utf8)
        #expect(after.contains("buffered"))
    }

    @Test("debug records are dropped below the minimum level")
    func debugDropped() async throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir)
        sink.enqueue(record(.debug, "chatter"))
        await sink.flush()
        let text = (try? String(contentsOf: sink.currentFileURL, encoding: .utf8)) ?? ""
        #expect(text.contains("chatter") == false)
    }

    @Test("lowering the minimum level lets debug through")
    func debugAdmittedWhenConfigured() async throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir, minimumLevel: .debug)
        sink.enqueue(record(.debug, "chatter"))
        await sink.flush()
        let text = try String(contentsOf: sink.currentFileURL, encoding: .utf8)
        #expect(text.contains("chatter"))
    }

    @Test("each line is valid JSON carrying the record shape")
    func linesAreJSON() async throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir)
        sink.enqueue(record(.notice, "shaped"))
        await sink.flush()
        let text = try String(contentsOf: sink.currentFileURL, encoding: .utf8)
        let first = text.split(separator: "\n")[0]
        let object = try JSONSerialization.jsonObject(with: Data(first.utf8)) as! [String: Any]
        #expect(object["level"] as? String == "notice")
        #expect(object["category"] as? String == "models")
        #expect(object["message"] as? String == "shaped")
        #expect(object["template"] as? String == "shaped")
    }

    @Test("a write failure disables the sink instead of trapping")
    func writeFailureDisables() async {
        let unwritable = URL(fileURLWithPath: "/dev/null/nope", isDirectory: true)
        let sink = FileDiagnosticsSink(directory: unwritable)
        sink.enqueue(record(.error, "boom"))
        await sink.flush()
        #expect(sink.isDisabled)
    }
}
