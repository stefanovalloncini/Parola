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

    private func waitForContent(
        _ substring: String, in url: URL, timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(substring) {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("expected \"\(substring)\" in \(url.path) within \(timeout)")
    }

    @Test("an error flushes to disk without an explicit flush")
    func errorFlushesEagerly() async throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir)
        sink.enqueue(record(.error, "boom"))
        try await waitForContent("boom", in: sink.currentFileURL)
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

    @Test("an unwritable directory disables the sink instead of trapping")
    func unwritableDirectoryDisables() async {
        let unwritable = URL(fileURLWithPath: "/dev/null/nope", isDirectory: true)
        let sink = FileDiagnosticsSink(directory: unwritable)
        sink.enqueue(record(.error, "boom"))
        await sink.flush()
        #expect(sink.isDisabled)
    }

    @Test("the sink never blocks a caller on its own file queue")
    func neverBlocksOnTheFileQueue() throws {
        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/ParolaCoreTests/FileDiagnosticsSinkTests.swift",
                with: "Sources/ParolaCore/Diagnostics/FileDiagnosticsSink.swift"
            ),
            encoding: .utf8
        )
        #expect(
            source.contains("fileQueue.sync") == false,
            "fileQueue.sync deadlocks when reached from inside a fileQueue closure, and puts disk I/O on the caller's thread"
        )
    }

    @Test("concurrent enqueues across a rotation boundary lose no records")
    func concurrentEnqueuesAcrossRotationLoseNothing() async throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir, maxFileBytes: 2_000)
        let total = 200
        let entry = record(.info, "line")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<total {
                group.addTask { sink.enqueue(entry) }
            }
        }
        await sink.flush()

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("parola-") && $0.pathExtension == "jsonl" }
        var lineCount = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            lineCount += text.split(separator: "\n").count
        }
        #expect(lineCount == total)
    }
}
