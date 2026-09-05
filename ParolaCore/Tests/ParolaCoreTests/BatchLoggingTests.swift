import Foundation
import Testing
@testable import ParolaCore

@Suite("Batch logging", .serialized, .logFacade)
struct BatchLoggingTests {
    private func withSink(_ body: (ScopedCapturingSink) async throws -> Void) async rethrows {
        let sink = ScopedCapturingSink()
        ParolaLog.install(sink)
        defer { ParolaLog.uninstall() }
        try await sink.scope { try await body(sink) }
    }

    private func batchRecords(
        _ sink: ScopedCapturingSink, message: String
    ) -> [LogRecord] {
        sink.records.filter { $0.category == .batch && $0.message.rendered == message }
    }

    private func makeQueue(
        behavior: StubTranscriber.Behavior = .succeed,
        features: FeatureSet = .all
    ) async throws -> (queue: BatchQueue, audioURL: URL) {
        let factory = StubFactory(behavior: behavior)
        let registry = EngineRegistry()
        await registry.register(engineID: .whisperKit, capabilities: .whisperKitDefaults) { _ in
            StubTranscriber(behavior: behavior, factory: factory)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-batch-logging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ModelStore(modelsDirectory: directory)
        try store.seedInstalledModel("openai_whisper-tiny")
        let audioURL = directory.appendingPathComponent("input.wav")
        try Data("RIFFstub".utf8).write(to: audioURL)
        let session = TranscriptionSession(modelStore: store, registry: registry)
        return (BatchQueue(session: session, features: features), audioURL)
    }

    private func drain(_ events: AsyncStream<BatchEvent>) async {
        for await _ in events {}
    }

    private func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    @Test("a queue refused by the feature gate is logged once, with the job count")
    func refusedQueue() async throws {
        try await withSink { sink in
            let (queue, audioURL) = try await makeQueue(features: FeatureSet(enabled: []))
            let jobs = [BatchJob(url: audioURL), BatchJob(url: audioURL)]
            await drain(queue.process(jobs: jobs, options: TranscriptionOptions(model: "openai_whisper-tiny")))

            let records = batchRecords(sink, message: "batch refused: batch disabled")
            #expect(records.count == 1)
            let record = try #require(records.first)
            #expect(record.level == .notice)
            #expect(record.fields[.count]?.text == "2")
            #expect(batchRecords(sink, message: "batch finished").isEmpty)
        }
    }

    @Test("a job that throws is logged with its id, its error and how long it ran")
    func failedJob() async throws {
        try await withSink { sink in
            let (queue, audioURL) = try await makeQueue()
            let missing = audioURL.deletingLastPathComponent().appendingPathComponent("gone.wav")
            let job = BatchJob(url: missing)
            await drain(queue.process(jobs: [job], options: TranscriptionOptions(model: "openai_whisper-tiny")))

            let record = try #require(batchRecords(sink, message: "job failed").first)
            #expect(record.level == .error)
            #expect(record.fields[.job]?.text == shortID(job.id))
            #expect(record.fields[.elapsed] != nil)
            #expect(record.fields[.error] != nil)
            #expect(record.formattedLine.contains("gone.wav") == false)
        }
    }

    @Test("a cancelled job is information, not an error")
    func cancelledJob() async throws {
        try await withSink { sink in
            let (queue, audioURL) = try await makeQueue(behavior: .cancel)
            let job = BatchJob(url: audioURL)
            await drain(queue.process(jobs: [job], options: TranscriptionOptions(model: "openai_whisper-tiny")))

            let record = try #require(batchRecords(sink, message: "job cancelled").first)
            #expect(record.level == .info)
            #expect(record.fields[.job]?.text == shortID(job.id))
            #expect(batchRecords(sink, message: "job failed").isEmpty)
        }
    }

    @Test("a finished queue reports how many jobs it ran")
    func finishedQueue() async throws {
        try await withSink { sink in
            let (queue, audioURL) = try await makeQueue()
            let jobs = [BatchJob(url: audioURL), BatchJob(url: audioURL)]
            await drain(queue.process(jobs: jobs, options: TranscriptionOptions(model: "openai_whisper-tiny")))

            let records = batchRecords(sink, message: "batch finished")
            #expect(records.count == 1)
            let record = try #require(records.first)
            #expect(record.level == .info)
            #expect(record.fields[.count]?.text == "2")
        }
    }
}
