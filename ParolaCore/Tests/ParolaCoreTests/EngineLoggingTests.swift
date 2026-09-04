import Foundation
import Testing
@testable import ParolaCore

@Suite("Engine logging", .serialized, .logFacade)
struct EngineLoggingTests {
    private func withSink(_ body: (CapturingDiagnosticsSink) async throws -> Void) async rethrows {
        let sink = CapturingDiagnosticsSink()
        ParolaLog.install(sink)
        defer { ParolaLog.uninstall() }
        try await body(sink)
    }

    private func temporaryStore() throws -> ModelStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-engine-logging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ModelStore(modelsDirectory: directory)
    }

    @Test("whisperkit reports a transcribe with no model loaded as a fault")
    func whisperKitTranscribeWithoutModel() async throws {
        try await withSink { sink in
            let engine = WhisperKitTranscriber(modelStore: try temporaryStore())
            await #expect(throws: ParolaError.self) {
                _ = try await engine.transcribe(
                    url: URL(fileURLWithPath: "/dev/null"),
                    options: TranscriptionOptions(),
                    handlers: TranscribeHandlers()
                )
            }
            let record = try #require(sink.records.first { $0.category == .engineWhisperKit })
            #expect(record.level == .fault)
            #expect(record.message.rendered == "transcribe called with no model loaded")
            #expect(record.fields.isEmpty)
        }
    }

    @Test("whisperkit reports a model that would not load")
    func whisperKitLoadFailure() async throws {
        try await withSink { sink in
            let engine = WhisperKitTranscriber(modelStore: try temporaryStore())
            await #expect(throws: ParolaError.self) {
                try await engine.load(model: "openai_whisper-tiny")
            }
            let record = try #require(sink.records.first { $0.category == .engineWhisperKit })
            #expect(record.level == .error)
            #expect(record.message.rendered == "model openai_whisper-tiny failed to load")
            #expect(record.fields[.error] != nil)
            #expect(record.formattedLine.contains("/") == false)
        }
    }

    @Test("parakeet reports a transcribe with no model loaded as a fault")
    func parakeetTranscribeWithoutModel() async throws {
        try await withSink { sink in
            let engine = ParakeetTranscriber(modelStore: try temporaryStore())
            await #expect(throws: ParolaError.self) {
                _ = try await engine.transcribe(
                    url: URL(fileURLWithPath: "/dev/null"),
                    options: TranscriptionOptions(),
                    handlers: TranscribeHandlers()
                )
            }
            let record = try #require(sink.records.first { $0.category == .engineParakeet })
            #expect(record.level == .fault)
            #expect(record.message.rendered == "transcribe called with no model loaded")
        }
    }

    // The remaining engine seams need a loaded CoreML model or an older OS to reach, so they are
    // pinned in source the way SpotlightIndexerLoggingTests pins its two catch blocks.
    private func engineSource(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "Tests/ParolaCoreTests/EngineLoggingTests.swift",
            with: "Sources/ParolaCore/Transcription/\(name).swift"
        )
        let source = try String(contentsOfFile: path, encoding: .utf8)
        return source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func expectCalls(_ calls: [String], in source: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for call in calls {
            #expect(source.contains(call), "missing log site: \(call)", sourceLocation: sourceLocation)
        }
    }

    @Test("the whisperkit engine logs load, download and result failures")
    func whisperKitSites() throws {
        let source = try engineSource("WhisperKitTranscriber")
        expectCalls([
            #"ParolaLog.info( .engineWhisperKit, "model \(ModelToken(model)) loaded", [.elapsed: .duration(startedAt.duration(to: .now))]"#,
            #"ParolaLog.error( .engineWhisperKit, "model \(ModelToken(model)) failed to load", [.error: .error(error)]"#,
            #"ParolaLog.error( .models, "whisperkit download failed for \(ModelToken(variant))", [.error: .error(error)]"#,
            #"ParolaLog.fault(.engineWhisperKit, "transcribe called with no model loaded")"#,
            #"ParolaLog.error( .engineWhisperKit, "engine returned no results", Self.emptyResultFields(model: modelName, url: url)"#,
            #"ParolaLog.error( .engineWhisperKit, "engine returned an empty result set", Self.emptyResultFields(model: modelName, url: url)"#,
            #"ParolaLog.info( .engineWhisperKit, "language probe inconclusive", [.count: .int(readings.count)]"#,
            #"fields[.audioSeconds] = .seconds(seconds)"#,
        ], in: source)
        #expect(source.components(separatedBy: "ParolaLog.").count - 1 == 7)
    }

    @Test("the parakeet engine logs load, rejection, transcribe and download failures")
    func parakeetSites() throws {
        let source = try engineSource("ParakeetTranscriber")
        expectCalls([
            #"ParolaLog.error( .engineParakeet, "model \(ModelToken(model)) failed to load", [.error: .error(error)]"#,
            #"ParolaLog.fault(.engineParakeet, "transcribe called with no model loaded")"#,
            #"ParolaLog.notice(.engineParakeet, "rejected language \(LanguageToken(lang))")"#,
            #"ParolaLog.notice(.engineParakeet, "rejected translate: unsupported")"#,
            #"ParolaLog.error(.engineParakeet, "transcribe failed", fields)"#,
            #"ParolaLog.error( .models, "parakeet download failed for \(ModelToken(model))", [.error: .error(error)]"#,
            #"var fields: [LogField: LogValue] = [ .model: .safe(ModelToken(modelName)), .elapsed: .duration(startedAt.duration(to: .now)), .error: .error(error), ]"#,
            #"fields[.audioSeconds] = .seconds(seconds)"#,
        ], in: source)
        #expect(source.components(separatedBy: "ParolaLog.").count - 1 == 6)
    }

    @Test("the apple speech engine logs the OS floor, setup and transcribe failures")
    func appleSpeechSites() throws {
        let source = try engineSource("AppleSpeechTranscriber")
        expectCalls([
            #"ParolaLog.notice(.engineAppleSpeech, "engine unavailable on this OS")"#,
            #"ParolaLog.error(.engineAppleSpeech, "analyzer setup failed", [.error: .error(error)])"#,
            #"ParolaLog.error( .engineAppleSpeech, "transcribe failed", [ .audioSeconds: .seconds(durationSeconds), .elapsed: .duration(startedAt.duration(to: .now)), .error: .error(error), ]"#,
        ], in: source)
        #expect(source.components(separatedBy: "ParolaLog.").count - 1 == 3)
    }

    private func callArguments(startingAt text: String) -> String {
        var depth = 0
        var call = ""
        for character in text {
            call.append(character)
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { break }
            }
        }
        return call
    }

    @Test("no engine hands an error's localized description to the log")
    func enginesNeverLogLocalizedDescriptions() throws {
        for name in ["WhisperKitTranscriber", "ParakeetTranscriber", "AppleSpeechTranscriber"] {
            let source = try engineSource(name)
            for chunk in source.components(separatedBy: "ParolaLog.").dropFirst() {
                let call = callArguments(startingAt: chunk)
                #expect(
                    call.contains("localizedDescription") == false,
                    "\(name) logs an error's localized description"
                )
            }
        }
    }
}
