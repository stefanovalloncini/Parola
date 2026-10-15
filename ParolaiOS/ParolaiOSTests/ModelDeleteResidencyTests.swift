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
    private let folderToFind: URL?

    init(log: EventLog, loaded: String?, busy: Bool = false, folderToFind: URL? = nil) {
        self.log = log
        self.loaded = loaded
        self.busy = busy
        self.folderToFind = folderToFind
    }

    func finishRun() { busy = false }
    func loadedModelName() async -> String? { loaded }

    func unloadModel(ifLoaded name: String) async {
        guard !busy else { return log.add("skipped, busy") }
        guard loaded == name else { return }
        loaded = nil
        log.add("unloaded \(name)")
        if let folderToFind { log.add("files present: \(FileManager.default.fileExists(atPath: folderToFind.path))") }
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

    @Test("a second delete of a model already being deleted does nothing")
    func guardsInFlight() async throws {
        let model = try makeModel()
        let log = EventLog()
        model.coordinator.modelResidency = ModelResidencyCoordinator(streaming: RecordingStreaming(log: log))
        let store = emptyStore()

        let first = model.deleteModel(Self.name, in: store)
        let second = model.deleteModel(Self.name, in: store)
        await first?.value

        #expect(second == nil)
        #expect(log.events == ["evict \(Self.name)"])
        #expect(model.modelsBeingDeleted.isEmpty)
    }

    @Test("deleting a model evicts it from the streaming cache and unloads the loaded session")
    func evictsAndUnloads() async throws {
        let model = try makeModel()
        let log = EventLog()
        let session = FakeSession(log: log, loaded: Self.name)
        model.coordinator.modelResidency = ModelResidencyCoordinator(streaming: RecordingStreaming(log: log))
        model.coordinator.modelResidency.attach(fileSession: session, dictationSession: { nil })

        await model.deleteModel(Self.name, in: emptyStore())?.value

        #expect(log.events == ["evict \(Self.name)", "unloaded \(Self.name)"])
    }

    @Test("the model's files are still there when it is unloaded, and gone after")
    func filesGoAfterTheUnload() async throws {
        let model = try makeModel()
        let log = EventLog()
        let store = emptyStore()
        let folder = store.installedURL(for: Self.name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = FakeSession(log: log, loaded: Self.name, folderToFind: folder)
        model.coordinator.modelResidency = ModelResidencyCoordinator(streaming: RecordingStreaming(log: log))
        model.coordinator.modelResidency.attach(fileSession: session, dictationSession: { nil })

        await model.deleteModel(Self.name, in: store)?.value

        #expect(log.events == ["evict \(Self.name)", "unloaded \(Self.name)", "files present: true"])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
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

        await model.deleteModel(Self.name, in: emptyStore())?.value
        #expect(log.events == ["evict \(Self.name)", "skipped, busy"])

        await session.finishRun()
        residency.sessionRunEnded()
        await residency.awaitRetry()

        #expect(log.events.last == "unloaded \(Self.name)")
    }
}
