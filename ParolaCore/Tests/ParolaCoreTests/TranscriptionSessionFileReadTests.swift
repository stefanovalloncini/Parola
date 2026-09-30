import Foundation
import Testing
@testable import ParolaCore
import ParolaTestSupport

@Suite("Transcription session file-read deadline", .serialized)
struct TranscriptionSessionFileReadTests {
    actor StubTranscriber: Transcriber {
        static let engineID = EngineID.whisperKit
        static let capabilities = EngineCapabilities.whisperKitDefaults

        private var loaded: String?

        func load(model: String) async throws { loaded = model }
        func unload() async { loaded = nil }
        func loadedModelName() async -> String? { loaded }

        func transcribe(
            url: URL, options: TranscriptionOptions, handlers: TranscribeHandlers
        ) async throws -> Transcript {
            Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "ok")],
                language: "en",
                modelName: loaded ?? "?",
                sourceURL: url,
                durationSeconds: 1
            )
        }
    }

    /// Stands in for a volume pulled after the readability gate has already passed: the file the
    /// energy probe reaches for is a FIFO nothing will ever write to.
    actor SwapsTheFileForAFifo: Transcriber {
        static let engineID = EngineID.whisperKit
        static let capabilities = EngineCapabilities.whisperKitDefaults

        private var loaded: String?

        func load(model: String) async throws { loaded = model }
        func unload() async { loaded = nil }
        func loadedModelName() async -> String? { loaded }

        func transcribe(
            url: URL, options: TranscriptionOptions, handlers: TranscribeHandlers
        ) async throws -> Transcript {
            try FileManager.default.removeItem(at: url)
            guard mkfifo(url.path, 0o644) == 0 else {
                throw ParolaError.ioError("could not create the FIFO the test needs")
            }
            return Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "ok")],
                language: "en",
                modelName: loaded ?? "?",
                sourceURL: url,
                durationSeconds: 1
            )
        }
    }

    private func makeSession(
        in directory: URL,
        transcriber: (any Transcriber)? = nil,
        fileReadDeadline: Duration = .seconds(3),
        abandonGrace: Duration = .seconds(5)
    ) async throws -> TranscriptionSession {
        let registry = EngineRegistry()
        let stub = transcriber ?? StubTranscriber()
        await registry.register(
            engineID: .whisperKit,
            capabilities: .whisperKitDefaults
        ) { _ in stub }
        let store = ModelStore(modelsDirectory: directory)
        try store.seedInstalledModel("openai_whisper-tiny")
        return TranscriptionSession(
            modelStore: store,
            registry: registry,
            fileReadDeadline: fileReadDeadline,
            abandonGrace: abandonGrace
        )
    }

    /// A FIFO with no writer parks `open()` exactly the way a TCC-denied folder or a stalled
    /// share does, and neither one can be cancelled out of.
    @Test("a file that never opens fails the run and leaves the next one free to start")
    func wedgedOpenFailsAndFreesThePipeline() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-fileread-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wedged = dir.appendingPathComponent("wedged.wav")
        #expect(mkfifo(wedged.path, 0o644) == 0, "could not create the FIFO the test needs")

        let readable = dir.appendingPathComponent("readable.wav")
        try Data("RIFFstub".utf8).write(to: readable)

        let session = try await makeSession(in: dir)
        let options = TranscriptionOptions(model: "openai_whisper-tiny")

        await FIFOFixture.holding(wedged) {
            let run = GuardedTask {
                try await session.transcribe(source: FileAudioSource(url: wedged), options: options)
            }
            do {
                if try await run.value("the run on a file that never opens to give up") != nil {
                    Issue.record("a run on a file that never opens should fail")
                }
            } catch ParolaError.fileReadTimedOut(let name) {
                #expect(name == "wedged.wav")
            } catch {
                Issue.record("expected fileReadTimedOut, got \(error)")
            }
        }

        let next = GuardedTask {
            try await session.transcribe(source: FileAudioSource(url: readable), options: options)
        }
        let transcript = try await next.value("the next run to start once the wedged one gave up")
        #expect(transcript?.segments.count == 1)
    }

    @Test("cancelling inside the gate hands the slot over without waiting out the deadline")
    func cancelInsideTheGateFreesTheSlot() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-gatecancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wedged = dir.appendingPathComponent("wedged.wav")
        try Data("RIFFstub".utf8).write(to: wedged)
        let readable = dir.appendingPathComponent("readable.wav")
        try Data("RIFFstub".utf8).write(to: readable)

        let session = try await makeSession(
            in: dir, fileReadDeadline: .seconds(3600), abandonGrace: .milliseconds(200)
        )
        let inGate = TestSignal()
        let unpark = DispatchSemaphore(value: 0)
        defer { unpark.signal() }
        await session.useReadabilityProbe { url in
            guard url.lastPathComponent == "wedged.wav" else { return FileAudioSource(url: url).synchronousDuration() }
            inGate.fire()
            unpark.wait()
            return nil
        }
        let options = TranscriptionOptions(model: "openai_whisper-tiny")

        let cancelled = Task {
            try await session.transcribe(source: FileAudioSource(url: wedged), options: options)
        }
        await inGate.wait("the run to park inside the readability gate")
        cancelled.cancel()

        let next = GuardedTask {
            try await session.transcribe(source: FileAudioSource(url: readable), options: options)
        }
        let transcript = try await next.value("the next run to take the slot while the cancelled one is parked")
        #expect(transcript?.segments.count == 1)
    }

    @Test("a file that stops reading after the gate skips the energy pass instead of parking")
    func wedgedEnergyProbeSkipsInsteadOfParking() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-energy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let audioURL = dir.appendingPathComponent("vanishes.wav")
        try Data("RIFFstub".utf8).write(to: audioURL)

        let session = try await makeSession(in: dir, transcriber: SwapsTheFileForAFifo())
        let transcript = try await FIFOFixture.holding(audioURL) {
            let run = GuardedTask {
                try await session.transcribe(
                    source: FileAudioSource(url: audioURL),
                    options: TranscriptionOptions(model: "openai_whisper-tiny")
                )
            }
            return try await run.value("the run to finish while its file no longer reads")
        }
        #expect(transcript?.segments.count == 1)
    }
}
