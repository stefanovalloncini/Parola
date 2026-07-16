import Foundation
import Testing
@testable import ParolaCore

@Suite("Batch queue")
struct BatchQueueTests {
    @Test("BatchJob round-trips through Codable")
    func codable() throws {
        let url = URL(fileURLWithPath: "/tmp/whatever.wav")
        let job = BatchJob(url: url, status: .done, progress: 1)
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(BatchJob.self, from: data)
        #expect(decoded == job)
    }

    @Test("processing jobs against missing files reports failures in order")
    func failuresInOrder() async {
        let jobs = [
            BatchJob(url: URL(fileURLWithPath: "/tmp/no-such-file-1.wav")),
            BatchJob(url: URL(fileURLWithPath: "/tmp/no-such-file-2.wav")),
        ]
        let queue = BatchQueue()
        let events = await queue.process(jobs: jobs, options: TranscriptionOptions(model: "openai_whisper-tiny"))

        var failedOrder: [UUID] = []
        var sawFinished = false
        for await event in events {
            switch event {
            case .failed(let id, _): failedOrder.append(id)
            case .finished: sawFinished = true
            default: break
            }
        }
        #expect(sawFinished)
        #expect(failedOrder == jobs.map(\.id))
    }

    @Test("BatchEvent.cancelled exists alongside .failed in the enum surface")
    func cancelledCase() {
        let id = UUID()
        let cancelled = BatchEvent.cancelled(jobID: id)
        switch cancelled {
        case .cancelled(let jobID):
            #expect(jobID == id)
        default:
            Issue.record("expected .cancelled")
        }
    }

    @Test("mid-job CancellationError surfaces as .cancelled, not .failed")
    func midJobCancellationYieldsCancelled() async throws {
        let setup = try await makeQueue(behavior: .cancel)
        let job = BatchJob(url: setup.audioURL)
        let events = await setup.queue.process(
            jobs: [job],
            options: TranscriptionOptions(model: "openai_whisper-tiny")
        )

        var startedID: UUID?
        var cancelledID: UUID?
        var sawFailed = false
        var sawFinished = false
        for await event in events {
            switch event {
            case .started(let id): startedID = id
            case .cancelled(let id): cancelledID = id
            case .failed: sawFailed = true
            case .finished: sawFinished = true
            case .completed: break
            }
        }

        #expect(startedID == job.id)
        #expect(cancelledID == job.id)
        #expect(sawFailed == false)
        #expect(sawFinished)
    }

    @Test("cancelling the consuming task tears down the in-flight session via onTermination")
    func consumerCancellationTearsDownInFlight() async throws {
        let setup = try await makeQueue(behavior: .hang)
        let job = BatchJob(url: setup.audioURL)

        let consumer = Task {
            let events = await setup.queue.process(
                jobs: [job],
                options: TranscriptionOptions(model: "openai_whisper-tiny")
            )
            for await _ in events {}
        }
        // Wait until the stub is actually parked in-flight, not just for the .started event:
        // a cancel that lands before the hang unwinds the job at a cancellation checkpoint,
        // and there is legitimately nothing left for cancelInFlight to tear down.
        for _ in 0..<200 {
            if await setup.factory.hangEntered { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        consumer.cancel()
        _ = await consumer.value

        for _ in 0..<200 {
            let cancelled = await setup.factory.cancelledCount
            if cancelled > 0 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let cancelled = await setup.factory.cancelledCount
        #expect(cancelled >= 1, "cancelInFlight should fire when the consuming task is cancelled")
    }

    @Test("finished always trails the last per-job event in a multi-job run")
    func finishedTrailsAllJobEvents() async throws {
        let setup = try await makeQueue(behavior: .succeed)
        let jobs = [
            BatchJob(url: setup.audioURL),
            BatchJob(url: setup.audioURL),
            BatchJob(url: setup.audioURL),
        ]
        let events = await setup.queue.process(
            jobs: jobs,
            options: TranscriptionOptions(model: "openai_whisper-tiny")
        )

        var ordered: [String] = []
        for await event in events {
            switch event {
            case .started: ordered.append("started")
            case .completed: ordered.append("completed")
            case .failed: ordered.append("failed")
            case .cancelled: ordered.append("cancelled")
            case .finished: ordered.append("finished")
            }
        }
        #expect(ordered.last == "finished")
        #expect(ordered.count == jobs.count * 2 + 1)
    }

    @Test("a wave that finishes cleanly does not cancel the shared session's in-flight work")
    func finishedWaveDoesNotCancelSharedSession() async throws {
        let setup = try await makeQueue(behavior: .succeed)
        let events = await setup.queue.process(
            jobs: [BatchJob(url: setup.audioURL)],
            options: TranscriptionOptions(model: "openai_whisper-tiny")
        )
        for await _ in events {}

        try? await Task.sleep(for: .milliseconds(300))
        let cancelled = await setup.factory.cancelledCount
        #expect(cancelled == 0, "onTermination after .finished must not fire cancelInFlight on a shared session")
    }

    @Test("two sequential waves through one shared session resolve the transcriber once")
    func sharedSessionReusesTranscriberAcrossWaves() async throws {
        let setup = try await makeSession(behavior: .succeed)
        for _ in 0..<2 {
            let queue = BatchQueue(session: setup.session)
            let events = await queue.process(
                jobs: [BatchJob(url: setup.audioURL)],
                options: TranscriptionOptions(model: "openai_whisper-tiny")
            )
            var sawCompleted = false
            for await event in events {
                if case .completed = event { sawCompleted = true }
            }
            #expect(sawCompleted)
        }
        #expect(setup.transcribersCreated.count == 1)
    }

    @Test("started, completed, finished events fire for a single happy-path job")
    func happyPathOrdering() async throws {
        let setup = try await makeQueue(behavior: .succeed)
        let job = BatchJob(url: setup.audioURL)
        let events = await setup.queue.process(
            jobs: [job],
            options: TranscriptionOptions(model: "openai_whisper-tiny")
        )

        var startedID: UUID?
        var completedID: UUID?
        var sawFinished = false
        for await event in events {
            switch event {
            case .started(let id): startedID = id
            case .completed(let id, _): completedID = id
            case .finished: sawFinished = true
            default: break
            }
        }
        #expect(startedID == job.id)
        #expect(completedID == job.id)
        #expect(sawFinished)
    }

    private struct QueueSetup {
        let queue: BatchQueue
        let factory: StubFactory
        let audioURL: URL
    }

    private struct SessionSetup {
        let session: TranscriptionSession
        let factory: StubFactory
        let transcribersCreated: LiveCounter
        let audioURL: URL
    }

    private func makeSession(behavior: StubTranscriber.Behavior) async throws -> SessionSetup {
        let factory = StubFactory(behavior: behavior)
        let created = LiveCounter()
        let registry = EngineRegistry()
        await registry.register(
            engineID: .whisperKit,
            capabilities: .whisperKitDefaults
        ) { [factory, created] _ in
            created.increment()
            return StubTranscriber(behavior: behavior, factory: factory)
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-batch-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ModelStore(modelsDirectory: dir)
        let installedDir = store.installedURL(for: "openai_whisper-tiny")
        try FileManager.default.createDirectory(at: installedDir, withIntermediateDirectories: true)
        let session = TranscriptionSession(modelStore: store, registry: registry, idleTimeout: 5)
        let audioURL = dir.appendingPathComponent("input.wav")
        try Data("RIFFstub".utf8).write(to: audioURL)
        return SessionSetup(session: session, factory: factory, transcribersCreated: created, audioURL: audioURL)
    }

    private func makeQueue(behavior: StubTranscriber.Behavior) async throws -> QueueSetup {
        let setup = try await makeSession(behavior: behavior)
        return QueueSetup(queue: BatchQueue(session: setup.session), factory: setup.factory, audioURL: setup.audioURL)
    }
}

actor StubFactory {
    var cancelledCount = 0
    var hangEntered = false
    init(behavior: StubTranscriber.Behavior) {}
    func recordCancellation() { cancelledCount += 1 }
    func recordHangEntered() { hangEntered = true }
}

actor StubTranscriber: Transcriber {
    enum Behavior: Sendable {
        case succeed
        case cancel
        case hang
    }

    static let engineID = EngineID("stub-engine")
    static let capabilities = EngineCapabilities.whisperKitDefaults

    private let behavior: Behavior
    private let factory: StubFactory
    private var loaded: String?
    private var inFlight: Task<Transcript, Error>?

    init(behavior: Behavior, factory: StubFactory) {
        self.behavior = behavior
        self.factory = factory
    }

    func load(model: String) async throws { loaded = model }
    func unload() async { loaded = nil }
    func loadedModelName() async -> String? { loaded }

    func transcribe(url: URL, options: TranscriptionOptions) async throws -> Transcript {
        switch behavior {
        case .succeed:
            return Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "ok")],
                language: "en",
                modelName: loaded ?? "?",
                sourceURL: url,
                durationSeconds: 1
            )
        case .cancel:
            throw CancellationError()
        case .hang:
            let task = Task<Transcript, Error> {
                try await Task.sleep(for: .seconds(60))
                throw CancellationError()
            }
            inFlight = task
            await factory.recordHangEntered()
            return try await task.value
        }
    }

    func cancelInFlight() async {
        inFlight?.cancel()
        inFlight = nil
        await factory.recordCancellation()
    }
}
