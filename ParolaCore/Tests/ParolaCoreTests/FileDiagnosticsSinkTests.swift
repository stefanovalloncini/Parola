import Foundation
import Testing
import ParolaTestSupport
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

    private func waitUntilDeleted(_ url: URL, timeout: Duration = .seconds(10)) async throws {
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
        await sink.waitForFileQueue()
        #expect(try String(contentsOf: sink.currentFileURL, encoding: .utf8).contains("boom"))
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

    @Test("a new file survives having the old one deleted underneath the sink")
    func startNewFileAfterDeletion() async throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir)
        sink.enqueue(record(.error, "before"))
        await sink.waitForFileQueue()
        #expect(try String(contentsOf: sink.currentFileURL, encoding: .utf8).contains("before"))

        await sink.startNewFile()
        for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: url)
        }

        sink.enqueue(record(.error, "after"))
        await sink.waitForFileQueue()
        #expect(try String(contentsOf: sink.currentFileURL, encoding: .utf8).contains("after"))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.count == 1)
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

    @Test("every line carries the schema version and a pinned set of keys")
    func linesCarrySchemaVersion() async throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir)
        sink.enqueue(record(.notice, "bare"))
        sink.enqueue(LogRecord(
            timestamp: Date(timeIntervalSince1970: 1_755_871_082),
            level: .notice, subsystem: .core, category: .models,
            message: "counted", fields: [.count: .int(3)],
            file: "T.swift", line: 1
        ))
        await sink.flush()

        let text = try String(contentsOf: sink.currentFileURL, encoding: .utf8)
        let objects = try text.split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        let common: Set<String> = [
            "schemaVersion", "ts", "level", "subsystem", "category", "message", "template",
            "file", "line",
        ]
        #expect(objects.allSatisfy { $0["schemaVersion"] as? Int == FileDiagnosticsSink.schemaVersion })
        #expect(Set(objects[0].keys) == common)
        #expect(Set(objects[1].keys) == common.union(["fields"]))
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

    @Test("every field's on-disk key is pinned")
    func fieldKeysArePinned() async throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir)
        let fields = Dictionary(uniqueKeysWithValues: LogField.allCases.map { ($0, LogValue.int(1)) })
        sink.enqueue(LogRecord(
            timestamp: Date(timeIntervalSince1970: 1_755_871_082),
            level: .notice, subsystem: .core, category: .models,
            message: "every field", fields: fields,
            file: "T.swift", line: 1
        ))
        await sink.flush()
        let text = try String(contentsOf: sink.currentFileURL, encoding: .utf8)
        let first = text.split(separator: "\n")[0]
        let object = try JSONSerialization.jsonObject(with: Data(first.utf8)) as! [String: Any]
        let keys = try #require(object["fields"] as? [String: String]).keys
        #expect(keys.sorted() == [
            "attempt", "audioSeconds", "bytes", "cancelled", "completed", "count", "elapsed",
            "energy", "engine", "entry", "error", "failed", "feature", "floor", "format", "job",
            "language", "mode", "model", "offset", "rotations", "stage",
        ])
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

    @Test("a synchronous drain puts buffered records on disk without an await")
    func flushSynchronouslyWritesTheBuffer() throws {
        let sink = FileDiagnosticsSink(directory: tempDirectory())
        sink.enqueue(record(.info, "breadcrumb"))
        sink.flushSynchronously()
        let text = try String(contentsOf: sink.currentFileURL, encoding: .utf8)
        #expect(text.contains("breadcrumb"))
    }

    @Test("only the exit drain blocks a caller on the sink's file queue")
    func onlyTheExitDrainBlocksOnTheFileQueue() throws {
        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/ParolaCoreTests/FileDiagnosticsSinkTests.swift",
                with: "Sources/ParolaCore/Diagnostics/FileDiagnosticsSink.swift"
            ),
            encoding: .utf8
        )
        #expect(
            source.components(separatedBy: "fileQueue.sync").count - 1 == 1,
            "fileQueue.sync deadlocks when reached from inside a fileQueue closure, and puts disk I/O on the caller's thread"
        )
        let drain = try #require(source.range(of: "func flushSynchronously()"))
        let body = source[drain.upperBound...]
        let end = try #require(body.range(of: "\n    }"))
        #expect(body[..<end.lowerBound].contains("fileQueue.sync"), "the exit drain is the only allowed blocker")
    }

    @Test("a full buffer drops records and reports how many")
    func fullBufferReportsDrops() async throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir, maxBufferedRecords: 2)
        sink.enqueue(record(.info, "one"))
        sink.enqueue(record(.info, "two"))
        sink.enqueue(record(.info, "three"))
        await sink.flush()

        let text = try String(contentsOf: sink.currentFileURL, encoding: .utf8)
        let objects = try text.split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        #expect(objects.compactMap { $0["message"] as? String }
            == ["one", "two", "diagnostics buffer full, records dropped"])
        #expect(objects.last?["category"] as? String == "diagnostics")
        #expect((objects.last?["fields"] as? [String: String])?["count"] == "1")
    }

    @Test("dropping the sink writes out what it still held")
    func deallocationDrains() async throws {
        let dir = tempDirectory()
        var sink: FileDiagnosticsSink? = FileDiagnosticsSink(directory: dir)
        let url = sink!.currentFileURL
        try await sink!.waitForInstallSweep()
        sink!.enqueue(record(.info, "last words"))
        sink = nil
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("last words"))
    }

    @Test("a rotation re-runs the retention sweep")
    func rotationSweepsAgain() async throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir, maxFileBytes: 400)
        try await sink.waitForInstallSweep()

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
