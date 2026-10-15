import Foundation
import os
import Testing
@testable import Parola
import ParolaCore

private final class EventLog: Sendable {
    private let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
    var events: [String] { lines.withLock { $0 } }
    func add(_ line: String) { lines.withLock { $0.append(line) } }
}

private struct RecordingStreaming: StreamingModelResidency {
    let log: EventLog
    func warm(_ name: String) async {}
    func releaseIdleModels() async {}
    func evict(_ name: String) async { log.add("evict \(name)") }
    func residentModelNames() async -> [String] { [] }
    func setIdleTimeout(_ timeout: Duration) async {}
}

private actor FakeSession: LoadedModelHolder {
    let log: EventLog
    private var loaded: String?
    private var busy: Bool

    init(log: EventLog, loaded: String?, busy: Bool = false) {
        self.log = log
        self.loaded = loaded
        self.busy = busy
    }

    func finishRun() { busy = false }
    func loadedModelName() async -> String? { loaded }

    func unloadModel(ifLoaded name: String) async {
        guard !busy else { return log.add("skipped, busy") }
        guard loaded == name else { return }
        loaded = nil
        log.add("unloaded \(name)")
    }

    func prewarm(modelName: String) async {}
}

@MainActor
@Suite("iOS model delete frees memory")
struct ModelDeleteResidencyTests {
    private static let name = "openai_whisper-tiny"

    private func makeModel() throws -> AppModel {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-model-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return AppModel(libraryURL: tmp, defaults: defaults)
    }

    private func emptyStore() -> ModelStore {
        ModelStore(modelsDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-model-store-\(UUID().uuidString)", isDirectory: true))
    }

    @Test("deleting a model evicts it from the streaming cache and unloads the loaded session")
    func evictsAndUnloads() async throws {
        let model = try makeModel()
        let log = EventLog()
        let session = FakeSession(log: log, loaded: Self.name)
        model.coordinator.modelResidency = ModelResidencyCoordinator(streaming: RecordingStreaming(log: log))
        model.coordinator.modelResidency.attach(fileSession: session, dictationSession: { nil })

        await model.deleteModel(Self.name, in: emptyStore()).value

        #expect(log.events == ["evict \(Self.name)", "unloaded \(Self.name)"])
    }

    @Test("a model still in use unloads once the run ends")
    func retriesAfterTheRun() async throws {
        let model = try makeModel()
        let log = EventLog()
        let session = FakeSession(log: log, loaded: Self.name, busy: true)
        let residency = ModelResidencyCoordinator(streaming: RecordingStreaming(log: log))
        model.coordinator.modelResidency = residency
        residency.attach(fileSession: session, dictationSession: { nil })
        residency.sessionRunBegan()

        await model.deleteModel(Self.name, in: emptyStore()).value
        #expect(log.events == ["evict \(Self.name)", "skipped, busy"])

        await session.finishRun()
        residency.sessionRunEnded()
        await residency.awaitRetry()

        #expect(log.events.last == "unloaded \(Self.name)")
    }
}
