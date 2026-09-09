import Foundation
import Testing
import ParolaTestSupport
@testable import ParolaCore

@Suite("Diagnostics export", .serialized, .logFacade)
struct DiagnosticsExportTests {
    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func line(
        ts: String,
        level: String = "info",
        subsystem: String = "app.parola.core",
        category: String = "models",
        message: String,
        fields: [String: String] = [:],
        schemaVersion: Int = FileDiagnosticsSink.schemaVersion
    ) throws -> String {
        var object: [String: Any] = [
            "schemaVersion": schemaVersion,
            "ts": ts,
            "level": level,
            "subsystem": subsystem,
            "category": category,
            "message": message,
        ]
        if !fields.isEmpty { object["fields"] = fields }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try #require(String(data: data, encoding: .utf8))
    }

    private func write(_ lines: [String], to directory: URL, named name: String) throws {
        let text = lines.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: directory.appendingPathComponent(name))
    }

    private var fullEnvironment: DiagnosticsEnvironment {
        DiagnosticsEnvironment(
            appVersion: "1.0.0",
            appBuild: "128",
            osVersion: "26.1 (25B12)",
            arch: "arm64",
            physicalMemoryBytes: 34_359_738_368,
            localeIdentifier: "en_GB",
            microphone: .granted,
            screenRecording: .denied,
            systemAudio: .undetermined,
            accessibility: .granted,
            engines: [.whisperKit: true, .parakeet: true, .appleSpeech: false],
            models: [
                .init(token: ModelToken("openai_whisper-large-v3_turbo"), bytes: 1_610_612_736),
            ],
            libraryEntryCount: 143,
            libraryBytes: 13_314_398_617,
            features: .all
        )
    }

    private var emptyEnvironment: DiagnosticsEnvironment {
        DiagnosticsEnvironment(
            osVersion: "26.1",
            arch: "arm64",
            physicalMemoryBytes: 17_179_869_184,
            localeIdentifier: "it_IT"
        )
    }

    @Test("records from every file merge into one timeline")
    func mergesFilesInTimestampOrder() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write([
            try line(ts: "2026-08-22T13:58:02.114Z", message: "first"),
            try line(ts: "2026-08-22T13:58:06.000Z", message: "fourth"),
        ], to: directory, named: "parola-100-1755871000.jsonl")
        try write([
            try line(ts: "2026-08-22T13:58:03.500Z", message: "second"),
            try line(ts: "2026-08-22T13:58:05.000Z", message: "third"),
        ], to: directory, named: "parola-200-1755871001.jsonl")

        let reading = DiagnosticsExport.read(directory: directory)
        #expect(reading.skippedLines == 0)
        #expect(reading.records.map(\.message) == ["first", "second", "third", "fourth"])
    }

    @Test("a line that is not JSON is skipped and counted")
    func skipsMalformedLines() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write([
            try line(ts: "2026-08-22T13:58:02.114Z", message: "kept"),
            "{ this is not json",
            "",
        ], to: directory, named: "parola-100-1755871000.jsonl")

        let reading = DiagnosticsExport.read(directory: directory)
        #expect(reading.records.map(\.message) == ["kept"])
        #expect(reading.skippedLines == 1)

        let text = DiagnosticsExport.render(directory: directory, environment: emptyEnvironment)
        #expect(text.contains("1 line skipped: unreadable or written by a newer version of Parola."))
    }

    @Test("a file that ends mid-character keeps the lines before the break")
    func keepsLinesBeforeATruncatedTail() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var data = Data((try line(ts: "2026-08-22T13:58:02.114Z", message: "kept") + "\n").utf8)
        data.append(contentsOf: [0x7B, 0x22, 0x74, 0xC3])
        try data.write(to: directory.appendingPathComponent("parola-100-1755871000.jsonl"))

        let reading = DiagnosticsExport.read(directory: directory)
        #expect(reading.records.map(\.message) == ["kept"])
        #expect(reading.skippedLines == 1)
        #expect(reading.skippedFiles == 0)
    }

    @Test("a file that cannot be read is counted, not dropped in silence")
    func countsUnreadableFiles() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write([try line(ts: "2026-08-22T13:58:02.114Z", message: "kept")],
                  to: directory, named: "parola-100-1755871000.jsonl")
        try write([try line(ts: "2026-08-22T13:58:03.000Z", message: "lost")],
                  to: directory, named: "parola-200-1755871001.jsonl")
        let blocked = directory.appendingPathComponent("parola-200-1755871001.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: blocked.path)
        }

        let reading = DiagnosticsExport.read(directory: directory)
        #expect(reading.records.map(\.message) == ["kept"])
        #expect(reading.skippedFiles == 1)

        let text = DiagnosticsExport.render(directory: directory, environment: emptyEnvironment)
        #expect(text.contains("1 file skipped: could not be read."))
    }

    @Test("a line from a newer schema is skipped and counted")
    func skipsNewerSchema() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write([
            try line(ts: "2026-08-22T13:58:02.114Z", message: "kept"),
            try line(
                ts: "2026-08-22T13:58:03.000Z",
                message: "from the future",
                schemaVersion: FileDiagnosticsSink.schemaVersion + 1
            ),
        ], to: directory, named: "parola-100-1755871000.jsonl")

        let reading = DiagnosticsExport.read(directory: directory)
        #expect(reading.records.map(\.message) == ["kept"])
        #expect(reading.skippedLines == 1)
    }

    @Test("a record whose timestamp will not parse sorts last")
    func unparsableTimestampSortsLast() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write([
            try line(ts: "not a date", message: "undated"),
            try line(ts: "2026-08-22T13:58:02.114Z", message: "dated"),
        ], to: directory, named: "parola-100-1755871000.jsonl")

        let reading = DiagnosticsExport.read(directory: directory)
        #expect(reading.records.map(\.message) == ["dated", "undated"])
        #expect(reading.skippedLines == 0)
    }

    @Test("the header reports every environment field")
    func headerReportsEveryField() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = DiagnosticsExport.render(
            directory: directory,
            environment: fullEnvironment,
            generatedAt: Date(timeIntervalSince1970: 1_755_871_391)
        )

        #expect(text.hasPrefix("Parola Diagnostics — generated 2025-08-22T14:03:11Z\n"))
        #expect(text.contains("No transcript text, file names, or paths are included."))
        #expect(text.contains("App 1.0.0 (128)  macOS 26.1 (25B12)  arm64  32 GB  en_GB"))
        #expect(text.contains(
            "Permissions         microphone=granted screenRecording=denied"
                + " systemAudio=undetermined accessibility=granted"
        ))
        #expect(text.contains("Engines registered  whisperkit=ok parakeet=ok apple-speech=unavailable"))
        #expect(text.contains("Models              openai_whisper-large-v3_turbo (1.5 GB)"))
        #expect(text.contains("Library             143 entries, 12.4 GB"))
        #expect(text.contains("Features            all enabled"))
        #expect(text.contains("No diagnostics recorded."))
    }

    /// The row asserts registration, not a model-load probe — every known engine, in the order the app and CLI register them, regardless of the dictionary's own iteration order.
    @Test("the engines row lists every known engine by name, in registry order")
    func engineRowListsKnownEnginesInRegistryOrder() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var environment = emptyEnvironment
        environment.engines = [.appleSpeech: false, .whisperKit: true, .parakeet: true]
        let text = DiagnosticsExport.render(directory: directory, environment: environment)

        #expect(text.contains("Engines registered  whisperkit=ok parakeet=ok apple-speech=unavailable"))
    }

    @Test("an unregistered engine id is appended after the known ones, scrubbed like any other unknown token")
    func engineRowAppendsUnknownEngineAfterKnownOnes() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var environment = emptyEnvironment
        environment.engines = [.appleSpeech: false, .whisperKit: true, .parakeet: true, EngineID("acme"): true]
        let text = DiagnosticsExport.render(directory: directory, environment: environment)

        #expect(text.contains(
            "Engines registered  whisperkit=ok parakeet=ok apple-speech=unavailable unrecognized=ok"
        ))
    }

    @Test("the header degrades where the frontend has no answer")
    func headerDegradesForMissingValues() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var environment = emptyEnvironment
        environment.features = FeatureSet(enabled: [.batch, .ai])
        let text = DiagnosticsExport.render(directory: directory, environment: environment)

        #expect(text.contains("App unknown  macOS 26.1  arm64  16 GB  it_IT"))
        #expect(text.contains("Permissions         unknown"))
        #expect(text.contains("Engines registered  unknown"))
        #expect(text.contains("Models              none installed"))
        #expect(text.contains("Library             unknown entries, not measured"))
        #expect(text.contains("Features            ai, batch"))
    }

    @Test("an unrecognized model id never reaches the header")
    func unknownModelIsNotEchoed() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var environment = emptyEnvironment
        environment.models = [.init(token: ModelToken("/Users/someone/Models/secret"), bytes: nil)]
        let text = DiagnosticsExport.render(directory: directory, environment: environment)

        #expect(text.contains("Models              unrecognized (size unknown)"))
        #expect(!text.contains("/Users/"))
    }

    @Test("an audio-load failure exports its kind, never the path it was given")
    func errorFieldCarriesNoPath() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failure = ParolaError.audioLoadFailed(
            URL(fileURLWithPath: "/Users/someone/Recordings/Board meeting.m4a"),
            underlying: "/Users/someone/Recordings/Board meeting.m4a could not be opened"
        )
        let sink = FileDiagnosticsSink(directory: directory, minimumLevel: .debug)
        sink.enqueue(
            LogRecord(
                timestamp: Date(timeIntervalSince1970: 1_755_871_082.114),
                level: .error,
                subsystem: .core,
                category: .audioCapture,
                message: "audio load failed",
                fields: [.error: .error(failure)],
                file: "AudioLoader.swift",
                line: 42
            )
        )
        await sink.flush()

        let text = DiagnosticsExport.render(directory: directory, environment: emptyEnvironment)
        #expect(text.contains("error=ParolaError.audioLoadFailed"))
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("Board meeting"))
    }

    @Test("the exported record line keeps the shape of LogRecord.formattedLine")
    func recordLineMatchesFormattedLine() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = LogRecord(
            timestamp: Date(timeIntervalSince1970: 1_755_871_082.114),
            level: .error,
            subsystem: .core,
            category: .engineWhisperKit,
            message: "transcribe failed",
            fields: [
                .elapsed: .seconds(61.2),
                .model: .safe(ModelToken("openai_whisper-large-v3_turbo")),
            ],
            file: "WhisperKitTranscriber.swift",
            line: 130
        )
        let sink = FileDiagnosticsSink(directory: directory, minimumLevel: .debug)
        sink.enqueue(record)
        await sink.flush()

        let fragments = record.formattedLine.components(separatedBy: "  ")
        try #require(fragments.count == 5)
        let text = DiagnosticsExport.render(directory: directory, environment: emptyEnvironment)
        #expect(text.contains(
            "\(fragments[0])  \(fragments[1])  core/\(fragments[2])  \(fragments[3])\n    \(fragments[4])"
        ))
    }

    @Test("an over-budget store keeps its newest records and says so")
    func capsAnOversizedDirectory() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldest = try line(ts: "2026-08-22T13:58:01.000Z", message: "oldest")
        let middle = try line(ts: "2026-08-22T13:58:02.000Z", message: "middle")
        let newest = try line(ts: "2026-08-22T13:58:03.000Z", message: "newest")
        let names = [
            "parola-100-1755871000.jsonl",
            "parola-200-1755871001.jsonl",
            "parola-300-1755871002.jsonl",
        ]
        let now = Date()
        for (index, content) in [oldest, middle, newest].enumerated() {
            try write([content], to: directory, named: names[index])
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(Double(index))],
                ofItemAtPath: directory.appendingPathComponent(names[index]).path
            )
        }

        let capped = DiagnosticsExport.read(directory: directory, maxBytes: newest.utf8.count + 1)
        #expect(capped.records.map(\.message) == ["newest"])
        #expect(capped.truncated)
        #expect(capped.skippedLines == 0)

        let whole = DiagnosticsExport.read(directory: directory)
        #expect(whole.records.map(\.message) == ["oldest", "middle", "newest"])
        #expect(!whole.truncated)
    }

    @Test("a file the budget cuts into contributes its last whole lines")
    func keepsWholeLinesFromACutFile() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try line(ts: "2026-08-22T13:58:01.000Z", message: "first")
        let second = try line(ts: "2026-08-22T13:58:02.000Z", message: "second")
        try write([first, second], to: directory, named: "parola-100-1755871000.jsonl")

        let reading = DiagnosticsExport.read(directory: directory, maxBytes: second.utf8.count + 5)
        #expect(reading.records.map(\.message) == ["second"])
        #expect(reading.skippedLines == 0)
        #expect(reading.truncated)

        // A cut that lands exactly on the newline before a record keeps that record.
        let onTheBoundary = DiagnosticsExport.read(
            directory: directory, maxBytes: second.utf8.count + 1
        )
        #expect(onTheBoundary.records.map(\.message) == ["second"])
        #expect(onTheBoundary.skippedLines == 0)
        #expect(onTheBoundary.truncated)
    }

    @Test("the report says when the cap dropped the oldest records")
    func rendersTheTruncationNotice() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try line(ts: "2026-08-22T13:58:01.000Z", message: "kept")
        try write([record, record], to: directory, named: "parola-100-1755871000.jsonl")

        let cap = record.utf8.count + 1
        let reading = DiagnosticsExport.read(directory: directory, maxBytes: cap)
        let text = DiagnosticsExport.render(
            reading: reading, environment: emptyEnvironment, generatedAt: Date()
        )
        #expect(text.contains("Oldest records dropped: the store is over the export's \(cap) bytes cap."))
    }

    @Test("an absent directory renders a report with no records")
    func absentDirectoryRendersEmptyReport() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-export-missing-\(UUID().uuidString)", isDirectory: true)
        let text = DiagnosticsExport.render(directory: missing, environment: emptyEnvironment)
        #expect(text.contains("No diagnostics recorded."))
        #expect(!text.contains("skipped"))
    }
}
