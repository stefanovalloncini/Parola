import Foundation
import Testing
import os
@preconcurrency import WhisperKit
@testable import ParolaCore

private let streamingSampleRate = 16_000

private struct StreamingLogFailure: Error {}

private final class FakeStreamingCapture: Sendable {
    // A named struct, not a tuple: a tuple element is lowered at the lock's opaque abstraction, so every `withLock` adds a reabstraction-thunk pair to the callback.
    private struct State {
        var callback: (@Sendable ([Float]) -> Bool)?
        var installed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ callback: @escaping @Sendable ([Float]) -> Bool) {
        state.withLock { $0 = State(callback: callback, installed: true) }
    }

    var installed: Bool { state.withLock { $0.installed } }

    func push(seconds: Double, value: Float) {
        let callback = state.withLock { $0.callback }
        _ = callback?([Float](repeating: value, count: Int(seconds * Double(streamingSampleRate))))
    }
}

@Suite("Streaming logging", .serialized)
struct StreamingLoggingTests {
    private func withSink(_ body: (CapturingDiagnosticsSink) async throws -> Void) async rethrows {
        let sink = CapturingDiagnosticsSink()
        try await ParolaLog.withSink(sink) { try await body(sink) }
    }

    private func streamingRecords(
        _ sink: CapturingDiagnosticsSink, message: String
    ) -> [LogRecord] {
        sink.records.filter { $0.category == .streaming && $0.message.rendered == message }
    }

    private func awaitRecord(
        _ sink: CapturingDiagnosticsSink, message: String
    ) async -> LogRecord? {
        for _ in 0..<500 {
            if let record = streamingRecords(sink, message: message).first { return record }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }

    private func temporaryStore() -> (store: ModelStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-streaming-logging-\(UUID().uuidString)", isDirectory: true)
        return (ModelStore(modelsDirectory: directory), directory)
    }

    // MARK: - Session

    @Test("a model whose engine can't stream is refused with a notice")
    func nonStreamingEngineRefused() async throws {
        try await withSink { sink in
            let (store, directory) = temporaryStore()
            defer { try? FileManager.default.removeItem(at: directory) }
            let session = StreamingTranscriptionSession(modelStore: store)
            do {
                _ = try await session.start(
                    options: TranscriptionOptions(model: "nvidia_parakeet-tdt-0.6b-v2")
                )
                Issue.record("expected ParolaError to be thrown")
            } catch is ParolaError {
            } catch {
                Issue.record("expected ParolaError but got \(error)")
            }
            let record = try #require(streamingRecords(sink, message: "engine parakeet cannot stream").first)
            #expect(record.level == .notice)
            #expect(record.fields.isEmpty)
            #expect(streamingRecords(sink, message: "streaming session starting on whisperkit").isEmpty)
        }
    }

    @Test("an accepted start reports the session and its model")
    func acceptedStartReported() async throws {
        try await withSink { sink in
            let (store, directory) = temporaryStore()
            defer { try? FileManager.default.removeItem(at: directory) }
            try store.seedInstalledModel("openai_whisper-tiny")
            let session = StreamingTranscriptionSession(modelStore: store)
            // The seeded directory holds no weights, so the model load fails offline right after.
            do {
                _ = try await session.start(options: TranscriptionOptions(model: "openai_whisper-tiny"))
                Issue.record("expected a throw but none occurred")
            } catch {
            }
            let record = try #require(
                streamingRecords(sink, message: "streaming session starting on whisperkit").first
            )
            #expect(record.level == .info)
            #expect(record.fields[.model]?.text == "openai_whisper-tiny")
            #expect(record.formattedLine.contains("/") == false)
        }
    }

    // MARK: - Realtime loop

    private func makeLoop(
        transcribeFailure: (any Error)? = nil,
        startFailure: (any Error)? = nil,
        permissionGranted: Bool = true
    ) -> (loop: StreamingRealtimeLoop, capture: FakeStreamingCapture) {
        let capture = FakeStreamingCapture()
        var config = StreamingRealtimeLoop.Configuration()
        config.useVAD = false
        let loop = StreamingRealtimeLoop(
            configuration: config,
            decodingOptions: DecodingOptions(),
            dependencies: .init(
                requestPermission: { permissionGranted },
                startCapture: { callback in
                    if let startFailure { throw startFailure }
                    capture.install(callback)
                },
                stopCapture: {},
                transcribe: { _, _, _ in
                    if let transcribeFailure { throw transcribeFailure }
                    return TranscriptionResult(
                        text: "", segments: [], language: "en", timings: TranscriptionTimings()
                    )
                },
                tick: { try await Task.sleep(nanoseconds: 1_000_000) }
            ),
            onPartial: { _ in },
            onEnergy: { _ in },
            onConfirmed: { _ in }
        )
        return (loop, capture)
    }

    @Test("a denied microphone is a notice, not an error")
    func micPermissionDenied() async throws {
        try await withSink { sink in
            let (loop, _) = makeLoop(permissionGranted: false)
            _ = await loop.run()
            let record = try #require(streamingRecords(sink, message: "microphone permission denied").first)
            #expect(record.level == .notice)
            #expect(record.fields.isEmpty)
        }
    }

    @Test("a capture that won't start is logged with its error")
    func captureStartFailure() async throws {
        try await withSink { sink in
            let (loop, _) = makeLoop(startFailure: StreamingLogFailure())
            _ = await loop.run()
            let record = try #require(
                streamingRecords(sink, message: "streaming capture failed to start").first
            )
            #expect(record.level == .error)
            #expect(record.fields[.error] != nil)
            #expect(record.fields[.elapsed] == nil)
        }
    }

    @Test("a failed iteration is logged once with how long the loop ran")
    func iterationFailure() async throws {
        try await withSink { sink in
            let (loop, capture) = makeLoop(transcribeFailure: StreamingLogFailure())
            let runTask = Task { await loop.run() }
            let deadline = ContinuousClock.now + .seconds(5)
            while !capture.installed, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard capture.installed else {
                runTask.cancel()
                _ = await runTask.value
                Issue.record("capture never installed")
                return
            }
            capture.push(seconds: 2, value: 0.5)
            _ = await runTask.value
            let records = streamingRecords(sink, message: "streaming iteration failed")
            #expect(records.count == 1)
            let record = try #require(records.first)
            #expect(record.level == .error)
            #expect(record.fields[.error] != nil)
            #expect(record.fields[.elapsed] != nil)
        }
    }

    @Test("polling the capture leaves its callback one frame deep")
    func pollingDoesNotNestTheCallback() {
        let capture = FakeStreamingCapture()
        let depths = OSAllocatedUnfairLock<[Int]>(initialState: [])
        capture.install { _ in
            depths.withLock { $0.append(Thread.callStackSymbols.count) }
            return true
        }
        capture.push(seconds: 0, value: 0)
        for _ in 0..<200 { _ = capture.installed }
        capture.push(seconds: 0, value: 0)
        let measured = depths.withLock { $0 }
        #expect(measured.count == 2)
        #expect(measured.first == measured.last)
    }

    // MARK: - Model cache

    @Test("a load failure the borrowers already saw is still reported once")
    func cachedLoadFailureReported() async throws {
        try await withSink { sink in
            let cache = StreamingModelCache { _, _ in throw StreamingLogFailure() }
            let (store, directory) = temporaryStore()
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                _ = try await cache.borrow("openai_whisper-tiny", store: store)
                Issue.record("expected StreamingLogFailure to be thrown")
            } catch is StreamingLogFailure {
            } catch {
                Issue.record("expected StreamingLogFailure but got \(error)")
            }
            let record = try #require(await awaitRecord(sink, message: "model load failed"))
            #expect(record.level == .error)
            #expect(record.fields[.model]?.text == "openai_whisper-tiny")
            #expect(record.fields[.error] != nil)
        }
    }

    @Test("a cancelled load is not reported as a failure")
    func cancelledLoadNotReported() async throws {
        try await withSink { sink in
            let cache = StreamingModelCache { _, _ in throw CancellationError() }
            let (store, directory) = temporaryStore()
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                _ = try await cache.borrow("openai_whisper-tiny", store: store)
                Issue.record("expected CancellationError to be thrown")
            } catch is CancellationError {
            } catch {
                Issue.record("expected CancellationError but got \(error)")
            }
            try await Task.sleep(for: .milliseconds(50))
            #expect(streamingRecords(sink, message: "model load failed").isEmpty)
        }
    }

    // MARK: - Source pins

    // The live-session seams need a loaded WhisperKit model and a running mic, so they are pinned in source.
    private func streamingSource(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "Tests/ParolaCoreTests/StreamingLoggingTests.swift",
            with: "Sources/ParolaCore/Engine/\(name).swift"
        )
        let source = try String(contentsOfFile: path, encoding: .utf8)
        return source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func expectCalls(_ calls: [String], in source: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for call in calls {
            #expect(source.contains(call), "missing log site: \(call)", sourceLocation: sourceLocation)
        }
    }

    @Test("the streaming session logs its lifecycle transitions and nothing per-partial")
    func sessionSites() throws {
        let source = try streamingSource("StreamingTranscriptionSession")
        expectCalls([
            #"ParolaLog.fault(.streaming, "start called while a session was already running")"#,
            #"ParolaLog.notice(.streaming, "engine \(variant.engineID) cannot stream")"#,
            #"ParolaLog.info( .streaming, "streaming session starting on whisperkit", [.model: .safe(ModelToken(modelName))]"#,
            #"ParolaLog.error( .streaming, "tokenizer was nil after model load", [.model: .safe(ModelToken(modelName))]"#,
            #"ParolaLog.info(.streaming, "take stopped before capture started")"#,
            #"ParolaLog.error(.streaming, "streaming failed", failureFields(error))"#,
            #"if loop != nil { ParolaLog.error(.streaming, "streaming loop ended without a stop request") }"#,
            #"var fields: [LogField: LogValue] = [.error: .error(error)] if let startedAt { fields[.elapsed] = .duration(startedAt.duration(to: .now)) }"#,
        ], in: source)
        #expect(source.components(separatedBy: "ParolaLog.").count - 1 == 7)
    }

    @Test("the realtime loop logs the three run outcomes and nothing per-iteration")
    func loopSites() throws {
        let source = try streamingSource("StreamingRealtimeLoop")
        expectCalls([
            #"ParolaLog.notice(.streaming, "microphone permission denied")"#,
            #"ParolaLog.error(.streaming, "streaming capture failed to start", [.error: .error(error)])"#,
            #"ParolaLog.error( .streaming, "streaming iteration failed", [.elapsed: .duration(startedAt.duration(to: .now)), .error: .error(error)]"#,
        ], in: source)
        #expect(source.components(separatedBy: "ParolaLog.").count - 1 == 3)
    }

    @Test("the model cache reports a swallowed load failure, each unload and a dropped lease with the model and nothing else")
    func cacheSites() throws {
        let source = try streamingSource("StreamingModelCache")
        expectCalls([
            #"if !isCancellation(error) { ParolaLog.error( .streaming, "model load failed", [.model: .safe(ModelToken(modelName)), .error: .error(error)]"#,
            #"ParolaLog.info( .streaming, "model unloaded after idle", [.model: .safe(ModelToken(name)), .elapsed: .duration(idleTimeout)]"#,
            #"ParolaLog.notice(.streaming, "model unloaded under memory pressure", [.model: .safe(ModelToken(name))])"#,
            #"ParolaLog.fault(.streaming, "a model lease was dropped without release", [.model: .safe(ModelToken(modelName))])"#,
        ], in: source)
        #expect(source.components(separatedBy: "ParolaLog.").count - 1 == 4)
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

    @Test("no streaming site hands an error's localized description to the log")
    func streamingNeverLogsLocalizedDescriptions() throws {
        for name in ["StreamingTranscriptionSession", "StreamingRealtimeLoop", "StreamingModelCache"] {
            let source = try streamingSource(name)
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
