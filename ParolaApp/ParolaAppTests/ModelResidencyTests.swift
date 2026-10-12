import Foundation
import os
import Testing
@testable import Parola
import ParolaCore
import ParolaDictation
import ParolaTestSupport

private final class EventLog: Sendable {
    private let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
    var events: [String] { lines.withLock { $0 } }
    func add(_ line: String) { lines.withLock { $0.append(line) } }
    func clear() { lines.withLock { $0.removeAll() } }
}

private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private final class FakeStreaming: StreamingModelResidency {
    let log: EventLog
    let warmGate: Gate?
    let onEvict: (@Sendable (String) -> Void)?
    private let resident = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let timeouts = OSAllocatedUnfairLock<[Duration]>(initialState: [])

    init(log: EventLog, warmGate: Gate? = nil, resident: [String] = [], onEvict: (@Sendable (String) -> Void)? = nil) {
        self.log = log
        self.warmGate = warmGate
        self.onEvict = onEvict
        self.resident.withLock { $0 = resident }
    }

    var idleTimeouts: [Duration] { timeouts.withLock { $0 } }

    func warm(_ name: String) async {
        log.add("warm \(name)")
        await warmGate?.wait()
    }

    func releaseIdleModels() async { log.add("release") }

    func evict(_ name: String) async {
        onEvict?(name)
        log.add("evict \(name)")
    }

    func residentModelNames() async -> [String] { resident.withLock { $0 } }
    func setIdleTimeout(_ timeout: Duration) async { timeouts.withLock { $0.append(timeout) } }
}

private actor FakeHolder: LoadedModelHolder {
    let label: String
    let log: EventLog
    private var loaded: String?
    private var busy = false

    init(_ label: String, log: EventLog, loaded: String? = nil, busy: Bool = false) {
        self.label = label
        self.log = log
        self.loaded = loaded
        self.busy = busy
    }

    func finishRun() { busy = false }
    func loadedModelName() async -> String? { loaded }

    func unloadModel(ifLoaded name: String) async {
        guard !busy else { return log.add("\(label) skipped, busy") }
        guard loaded == name else { return }
        loaded = nil
        log.add("\(label) unloaded \(name)")
    }

    func prewarm(modelName: String) async { log.add("\(label) prewarm \(modelName)") }
}

private actor ListeningRecorder: DictationRecorder {
    let log: EventLog
    init(log: EventLog) { self.log = log }
    func start() async throws {}
    func stopAndTranscribe() async throws -> String { "" }
    func stopAndDiscard() async {
        for _ in 0..<5 { await Task.yield() }
        log.add("discard")
    }
}

@MainActor
@Suite("Model residency")
struct ModelResidencyTests {
    private static let turbo = "openai_whisper-large-v3_turbo"

    private func makeModel() -> AppModel {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("residency"))
        model.dictationPerAppOverridesJSON = "{}"
        return model
    }

    private struct Rig {
        let model: AppModel
        let log: EventLog
        let streaming: FakeStreaming
        let file: FakeHolder
        let dictation: FakeHolder
    }

    private func makeRig(
        warmGate: Gate? = nil,
        resident: [String] = [],
        fileLoaded: String? = nil,
        fileBusy: Bool = false,
        onEvict: (@Sendable (String) -> Void)? = nil
    ) -> Rig {
        let model = makeModel()
        let log = EventLog()
        let streaming = FakeStreaming(log: log, warmGate: warmGate, resident: resident, onEvict: onEvict)
        let file = FakeHolder("file", log: log, loaded: fileLoaded, busy: fileBusy)
        let dictation = FakeHolder("dictation", log: log)
        model.modelResidency = ModelResidencyCoordinator(streaming: streaming)
        model.modelResidency.attach(fileSession: file, dictationSession: dictation)
        return Rig(model: model, log: log, streaming: streaming, file: file, dictation: dictation)
    }

    // MARK: - Dictation off

    @Test("turning dictation off releases the streaming models once the recorder has let go")
    func dictationOffReleasesAfterTheRecorder() async {
        let rig = makeRig()
        let model = rig.model
        model.dictationController.recorderFactory = { [log = rig.log] _ in ListeningRecorder(log: log) }
        model.dictationEnabled = true
        await model.dictationController.monitorWork?.value
        model.dictationController.simulatePress()
        await waitUntil { model.dictationState == .listening }
        rig.log.clear()

        model.turnOffDictation()
        await model.dictationController.monitorWork?.value

        #expect(rig.log.events == ["discard", "release"])
    }

    @Test("a streaming-off setting releases the models instead of warming one")
    func streamingOffReleases() async {
        let rig = makeRig()
        let model = rig.model
        model.useStreaming = false
        model.dictationController.recorderFactory = { [log = rig.log] _ in ListeningRecorder(log: log) }

        model.dictationEnabled = true
        await model.dictationController.monitorWork?.value

        #expect(rig.log.events == ["release"])
        #expect(!model.modelResidency.isWarming)
        model.abortDictation()
    }

    // MARK: - Tracked warm-up

    @Test("a restart does not start a second warm for the same model")
    func restartKeepsOneWarm() async {
        let gate = Gate()
        let rig = makeRig(warmGate: gate)
        let residency = rig.model.modelResidency

        residency.warmStreaming(Self.turbo)
        residency.warmStreaming(Self.turbo)
        await waitUntil { rig.log.events.count == 1 }
        await gate.release()
        await residency.awaitWarm()

        #expect(rig.log.events == ["warm \(Self.turbo)"])
        #expect(!residency.isWarming)
    }

    @Test("a warm for another model replaces the handle")
    func anotherModelReplacesTheWarm() async {
        let gate = Gate()
        let rig = makeRig(warmGate: gate)
        let residency = rig.model.modelResidency

        residency.warmStreaming(Self.turbo)
        residency.warmStreaming("openai_whisper-base")
        #expect(residency.warmingModel == "openai_whisper-base")
        await gate.release()
        await residency.awaitWarm()

        #expect(rig.log.events.contains("warm openai_whisper-base"))
        #expect(!residency.isWarming)
    }

    // MARK: - Picker

    @Test("opening the picker refreshes the list and warms nothing")
    func pickerAppearingDoesNotWarm() async {
        let rig = makeRig()

        rig.model.modelPickerAppeared()
        await rig.model.modelResidency.awaitFileWarm()
        await settle()

        #expect(rig.log.events.isEmpty)
    }

    @Test("picking an installed model warms it and picking a missing one only downloads")
    func pickingWarmsOnlyInstalledModels() async {
        let rig = makeRig()
        let downloads = OSAllocatedUnfairLock<[String]>(initialState: [])

        rig.model.pickModel("openai_whisper-base", isInstalled: false) { name in downloads.withLock { $0.append(name) } }
        await rig.model.modelResidency.awaitFileWarm()
        #expect(rig.log.events.isEmpty)
        #expect(downloads.withLock { $0 } == ["openai_whisper-base"])

        rig.model.pickModel(Self.turbo, isInstalled: true) { name in downloads.withLock { $0.append(name) } }
        await rig.model.modelResidency.awaitFileWarm()
        #expect(rig.log.events == ["file prewarm \(Self.turbo)"])
        #expect(downloads.withLock { $0 } == ["openai_whisper-base"])
        #expect(rig.model.selectedModel == Self.turbo)
    }

    // MARK: - Delete

    @Test("freeing a model evicts it from the streaming cache and unloads it from both sessions")
    func freeEvictsFromBothCaches() async {
        let rig = makeRig(fileLoaded: Self.turbo)

        await rig.model.modelResidency.free(Self.turbo)

        #expect(rig.log.events == ["evict \(Self.turbo)", "file unloaded \(Self.turbo)"])
    }

    @Test("a model a running session holds is unloaded when that run ends")
    func busySessionUnloadsAfterTheRun() async {
        let rig = makeRig(fileLoaded: Self.turbo, fileBusy: true)
        let residency = rig.model.modelResidency

        await residency.free(Self.turbo)
        #expect(rig.log.events.contains("file skipped, busy"))

        await rig.file.finishRun()
        residency.sessionRunEnded()
        await residency.awaitRetry()

        #expect(rig.log.events.last == "file unloaded \(Self.turbo)")
        residency.sessionRunEnded()
        await residency.awaitRetry()
        #expect(rig.log.events.filter { $0.hasPrefix("file unloaded") }.count == 1, "the retry is spent")
    }

    @Test("a run ending with nothing pending does not touch the sessions")
    func runEndWithoutPendingDoesNothing() async {
        let rig = makeRig(fileLoaded: Self.turbo)

        rig.model.modelResidency.sessionRunEnded()
        await rig.model.modelResidency.awaitRetry()

        #expect(rig.log.events.isEmpty)
    }

    @Test("deleting a model frees it before its files go")
    func deleteFreesBeforeRemovingFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelResidencyTests-\(UUID().uuidString)", isDirectory: true)
        let store = ModelStore(modelsDirectory: root)
        let live = store.installedURL(for: Self.turbo)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1_000).write(to: live.appendingPathComponent("weights.bin"))
        let filesWereThere = OSAllocatedUnfairLock(initialState: false)
        let rig = makeRig(fileLoaded: Self.turbo) { _ in
            filesWereThere.withLock { $0 = FileManager.default.fileExists(atPath: live.path) }
        }

        await rig.model.deleteModel(Self.turbo, in: store)?.value

        #expect(rig.log.events == ["evict \(Self.turbo)", "file unloaded \(Self.turbo)"])
        #expect(filesWereThere.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: live.path))
    }

    // MARK: - Bridge

    @Test("the resident list holds the streaming cache's models and what the sessions have loaded")
    func residentNamesJoinBothCaches() async {
        let rig = makeRig(resident: ["openai_whisper-base"], fileLoaded: Self.turbo)

        let names = await rig.model.modelResidency.residentModelNames()

        #expect(names == ["openai_whisper-base", Self.turbo].sorted())
    }

    @Test("getState carries models.resident")
    func stateCarriesResidentModels() throws {
        let model = makeModel()
        let server = try ParolaAutomationServer(model: model)

        guard case .object(let state) = server.snapshotState(residentModels: [Self.turbo]),
              case .object(let models)? = state["models"] else {
            Issue.record("getState has no models object")
            return
        }

        #expect(models["resident"] == .array([.string(Self.turbo)]))
    }

    @Test("the idle timeout reaches the streaming cache")
    func idleTimeoutIsForwarded() async {
        let rig = makeRig()

        await rig.model.modelResidency.setStreamingIdleTimeout(.seconds(5))

        #expect(rig.streaming.idleTimeouts == [.seconds(5)])
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Dictation fallback warm-up")
    struct DictationFallbackWarmTests {
        @Test("a non-streaming dictation press starts loading its model before the key is released")
        func pressWarmsTheFallbackModel() async throws {
            let audio = try makeTakeWAV("fallback-warm", seconds: 0.3)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared([.audioSource]) {
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: audio)
                let warmed = OSAllocatedUnfairLock<[String]>(initialState: [])
                let recorder = MicDictationRecorder(
                    model: "openai_whisper-large-v3_turbo",
                    language: nil,
                    streamingEnabled: false,
                    warmFallbackModel: { name in warmed.withLock { $0.append(name) } }
                )
                let beforeThePress = warmed.withLock { $0 }
                #expect(beforeThePress.isEmpty, "nothing loads while dictation is armed but not pressed")

                try await recorder.start()
                await waitUntil { warmed.withLock { $0 } == ["openai_whisper-large-v3_turbo"] }
                await recorder.stopAndDiscard()
            }
        }

        @Test("a streaming dictation press leaves the fallback session alone")
        func streamingPressDoesNotWarmTheFallback() async throws {
            let warmed = OSAllocatedUnfairLock<[String]>(initialState: [])
            let recorder = MicDictationRecorder(
                model: "openai_whisper-large-v3_turbo",
                language: nil,
                streamingEnabled: true,
                makeStreamingSession: { StubStreamingSession() },
                warmFallbackModel: { name in warmed.withLock { $0.append(name) } }
            )

            try await recorder.start()
            await settle()
            await recorder.stopAndDiscard()

            #expect(warmed.withLock { $0 }.isEmpty)
        }
    }
}

private struct StubStreamingSession: StreamingTranscriber {
    func start(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)?,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> AsyncStream<StreamingEvent> {
        AsyncStream { $0.finish() }
    }
    func stop() async {}
    func cancel() async {}
    func currentModel() async -> String? { nil }
}
