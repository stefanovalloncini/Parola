import Foundation
import Testing
@testable import ParolaCore

@Suite("File diagnostics sink", .serialized, .logFacade)
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
            level: level, subsystem: .core, category: .models,
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

    private func waitForInitialSweep(
        _ sink: FileDiagnosticsSink, timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if sink.completedSweeps > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the install-time sweep never finished")
    }

    private func waitUntilDeleted(_ url: URL, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("expected \(url.lastPathComponent) to be swept within \(timeout)")
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
        #expect(object["subsystem"] as? String == "app.parola.core")
    }

    @Test("field values persist as flat strings, without their kind")
    func fieldsPersistFlat() async throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir)
        sink.enqueue(LogRecord(
            timestamp: Date(timeIntervalSince1970: 1_755_871_082),
            level: .notice, subsystem: .core, category: .models,
            message: "sized", fields: [.bytes: .bytes(4823), .elapsed: .seconds(1.2)],
            file: "T.swift", line: 1
        ))
        await sink.flush()
        let text = try String(contentsOf: sink.currentFileURL, encoding: .utf8)
        let first = text.split(separator: "\n")[0]
        let object = try JSONSerialization.jsonObject(with: Data(first.utf8)) as! [String: Any]
        #expect(object["fields"] as? [String: String] == ["bytes": "4823", "elapsed": "1.20"])
    }

    @Test("an unwritable directory disables the sink instead of trapping")
    func unwritableDirectoryDisables() async {
        let unwritable = URL(fileURLWithPath: "/dev/null/nope", isDirectory: true)
        let sink = FileDiagnosticsSink(directory: unwritable)
        sink.enqueue(record(.error, "boom"))
        await sink.flush()
        #expect(sink.isDisabled)
    }

    @Test("a failing write disables the sink and drops the handle")
    func writeFailureDisables() async throws {
        let dir = tempDirectory()
        struct WriteRefused: Error {}
        let sink = FileDiagnosticsSink(directory: dir, write: { _, _ in throw WriteRefused() })
        sink.enqueue(record(.error, "boom"))
        await sink.flush()
        #expect(sink.isDisabled)

        sink.enqueue(record(.error, "after"))
        await sink.flush()
        let text = (try? String(contentsOf: sink.currentFileURL, encoding: .utf8)) ?? ""
        #expect(text.isEmpty, "a disabled sink must stop buffering, not queue records forever")
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

    @Test("dropping the sink writes out what it still held")
    func deallocationDrains() async throws {
        let dir = tempDirectory()
        var sink: FileDiagnosticsSink? = FileDiagnosticsSink(directory: dir)
        let url = sink!.currentFileURL
        try await waitForInitialSweep(sink!)
        sink!.enqueue(record(.info, "last words"))
        sink = nil
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("last words"))
    }

    @Test("a rotation re-runs the retention sweep")
    func rotationSweepsAgain() async throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir, maxFileBytes: 400)
        try await waitForInitialSweep(sink)

        let expired = dir.appendingPathComponent("parola-999999-100.jsonl")
        try Data(repeating: 0x61, count: 10).write(to: expired)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-9 * 86_400)],
            ofItemAtPath: expired.path
        )

        for _ in 0..<20 { sink.enqueue(record(.error, "spin")) }
        await sink.flush()
        try await waitUntilDeleted(expired)
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
