import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@Suite("Model label mapping")
struct ModelLabelTests {
    @Test("known model ids map to their friendly display name", arguments: [
        ("openai_whisper-large-v3_turbo", "Whisper Large v3 Turbo"),
        ("openai_whisper-tiny", "Whisper Tiny"),
    ])
    func knownIDsMapToDisplayName(id: String, expected: String) {
        #expect(AppModel.modelLabel(id) == expected)
    }

    @Test("an unknown model id falls back to its raw string")
    func unknownIDFallsBack() {
        #expect(AppModel.modelLabel("made-up-model-id") == "made-up-model-id")
    }

    @MainActor
    @Test("every catalog name reaches the intake button whole")
    func catalogLabelsAreNotCapped() {
        for name in ["Apple Speech (system)", "Whisper Turbo", "Whisper Tiny EN", "Parakeet v2", "Distil Large"] {
            #expect(ModelPickerView.capped(name) == name)
        }
        #expect(ModelPickerView.shortLabel(for: "Whisper Large v3 Turbo") == "Whisper Turbo")
    }

    @MainActor
    @Test("a label no catalog produced is capped so the intake button cannot outgrow its budget")
    func uncuratedLabelIsCapped() {
        let long = "community_whisper-large-v3-italian-finetune"
        let capped = ModelPickerView.capped(long)
        #expect(capped.count == ModelPickerView.labelCharacterCap)
        #expect(capped.hasSuffix("…"))
        #expect(long.hasPrefix(capped.dropLast()))
    }
}

@Suite("Engine streams-partials gate")
struct EngineStreamsPartialsTests {
    @Test("streaming engines report progressively, so an empty window means preparing", arguments: [
        "openai_whisper-large-v3_turbo",
        "openai_whisper-tiny",
        "apple-speech-analyzer",
    ])
    func streamingEnginesQualify(id: String) {
        #expect(AppModel.engineStreamsPartials(id))
    }

    @Test("Parakeet works silently until the end, so it never shows a preparing label")
    func parakeetDoesNotQualify() {
        #expect(!AppModel.engineStreamsPartials("nvidia_parakeet-tdt-0.6b-v2"))
    }

    @Test("an unknown model id defaults to streaming")
    func unknownIDDefaultsToStreaming() {
        #expect(AppModel.engineStreamsPartials("made-up-model-id"))
    }
}

@Suite("Preparing label stage gate")
@MainActor
struct PreparingStageGateTests {
    private func makeIsolatedDefaults() -> UserDefaults {
        temporaryDefaults()
    }

    @Test("a reported preparingAudio stage shows the label without waiting for the heuristic")
    func preparingStageShowsImmediately() {
        #expect(TranscribingPane.showsPreparing(stage: .preparingAudio, heuristic: false, awaitingFirstOutput: true))
    }

    @Test("a reported transcribing stage hides the label even before any output")
    func transcribingStageHidesLabel() {
        #expect(!TranscribingPane.showsPreparing(stage: .transcribing, heuristic: true, awaitingFirstOutput: true))
    }

    @Test("output on screen wins over a stale preparingAudio stage")
    func outputBeatsStaleStage() {
        #expect(!TranscribingPane.showsPreparing(stage: .preparingAudio, heuristic: true, awaitingFirstOutput: false))
    }

    @Test("without stage reports the grace-period heuristic still decides", arguments: [true, false])
    func noStageFallsBackToHeuristic(heuristic: Bool) {
        #expect(TranscribingPane.showsPreparing(stage: nil, heuristic: heuristic, awaitingFirstOutput: true) == heuristic)
    }

    @Test("stage reports drive AppModel.fileTranscribeStage")
    func modelTracksStages() {
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("stage"))
        #expect(model.fileTranscribeStage == nil)
        model.fileTranscribeStage = .preparingAudio
        #expect(TranscribingPane.showsPreparing(stage: model.fileTranscribeStage, heuristic: false, awaitingFirstOutput: true))
        model.fileTranscribeStage = .transcribing
        #expect(!TranscribingPane.showsPreparing(stage: model.fileTranscribeStage, heuristic: false, awaitingFirstOutput: true))
    }
}

@Suite("Selected-model correction")
struct SelectedModelCorrectionTests {
    private func info(_ name: String, installed: Bool) -> ModelInfo {
        ModelInfo(name: name, label: name, approximateSizeBytes: 0, isMultilingual: true, isInstalled: installed)
    }

    @Test("a catalog id that isn't actually installed corrects to the default, not just any known id")
    func uninstalledCatalogSelectionCorrects() {
        let models = [
            info("openai_whisper-tiny", installed: false),
            info("apple-speech-analyzer", installed: true),
        ]
        let corrected = AppModel.correctedSelectedModel(
            "openai_whisper-tiny", in: models, defaultModelID: "apple-speech-analyzer"
        )
        #expect(corrected == "apple-speech-analyzer")
    }

    @Test("an installed selection is left alone")
    func installedSelectionUntouched() {
        let models = [info("openai_whisper-tiny", installed: true)]
        let corrected = AppModel.correctedSelectedModel(
            "openai_whisper-tiny", in: models, defaultModelID: "should-not-be-used"
        )
        #expect(corrected == nil)
    }

    @Test("an id absent from the scan entirely also corrects")
    func unknownSelectionCorrects() {
        let models = [info("apple-speech-analyzer", installed: true)]
        let corrected = AppModel.correctedSelectedModel(
            "totally-uninstalled-model", in: models, defaultModelID: "apple-speech-analyzer"
        )
        #expect(corrected == "apple-speech-analyzer")
    }

    @Test("a selection whose download is in flight survives a scan even though it isn't installed yet")
    func downloadingSelectionSurvivesScan() {
        let models = [info("openai_whisper-small", installed: false)]
        let corrected = AppModel.correctedSelectedModel(
            "openai_whisper-small", in: models, downloading: "openai_whisper-small", defaultModelID: "should-not-be-used"
        )
        #expect(corrected == nil)
    }

    @Test("a download in flight for a different model does not protect the current, uninstalled selection")
    func downloadingUnrelatedModelDoesNotProtect() {
        let models = [info("openai_whisper-small", installed: false)]
        let corrected = AppModel.correctedSelectedModel(
            "openai_whisper-small", in: models, downloading: "openai_whisper-base", defaultModelID: "apple-speech-analyzer"
        )
        #expect(corrected == "apple-speech-analyzer")
    }
}

@MainActor
@Suite("A refused or failed download does not strand the selection")
struct DownloadRefusalCorrectionTests {
    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("download-refusal"))
    }

    private func waitUntil(timeoutMs: Int = 5_000, _ condition: @MainActor () -> Bool) async -> Bool {
        var elapsed = 0
        while elapsed < timeoutMs {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
            elapsed += 15
        }
        return condition()
    }

    @Test("a download refused while another job runs corrects the pick back to the default")
    func refusedDownloadCorrectsSelection() {
        let model = makeModel()
        model.availableModels = [
            ModelInfo(name: "openai_whisper-tiny", label: "Whisper Tiny", approximateSizeBytes: 0, isMultilingual: true, isInstalled: false),
        ]
        model.phase = .transcribing(file: URL(fileURLWithPath: "/dev/null"))
        model.activateModel("openai_whisper-tiny")

        let started = model.downloadModel("openai_whisper-tiny")

        #expect(started == false)
        #expect(model.modelActionError != nil)
        #expect(model.selectedModel == ModelCatalog.defaultModelID())
    }

    @Test("a download that fails after starting corrects the pick instead of leaving it stuck")
    func failedDownloadCorrectsSelection() async throws {
        let model = makeModel()
        // Not a real catalog id, but a close enough match that ModelStore rejects it before any
        // network call — the async catch path this proves must fire the same way a real failure would.
        let pickedID = "whisper-large-v3_turbo"
        model.availableModels = []
        model.activateModel(pickedID)

        let started = model.downloadModel(pickedID)
        #expect(started == true)

        let corrected = await waitUntil { model.selectedModel != pickedID }
        #expect(corrected)
        #expect(model.selectedModel == ModelCatalog.defaultModelID())
        #expect(model.modelActionError != nil)
    }
}

@Suite("Selectable model names")
struct SelectableModelNamesTests {
    private func info(_ name: String) -> ModelInfo {
        ModelInfo(name: name, label: name, approximateSizeBytes: 0, isMultilingual: true, isInstalled: true)
    }

    @Test("a junk folder isn't offered as a selectable model")
    func junkFolderExcluded() {
        let names = AppModel.selectableModelNames([
            info("openai_whisper-large-v3_turbo"),
            info("apple-speech-analyzer"),
            info("parakeet-tdt-0.6b-v2-coreml"),
        ])
        #expect(names == ["openai_whisper-large-v3_turbo", "apple-speech-analyzer"])
    }

    @Test("a real junk directory on disk is scanned as installed but still filtered out")
    func realJunkDirectoryStillFiltered() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelectableModelNamesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let junk = root
            .appendingPathComponent("models/FluidInference/junk-orphan-model", isDirectory: true)
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: junk.appendingPathComponent("model.bin"))

        let store = ModelStore(modelsDirectory: root)
        let scan = store.scan()
        let availableModels = scan.catalog + scan.installed.filter { entry in
            !scan.catalog.contains { $0.name == entry.name }
        }

        #expect(scan.installed.contains { $0.name == "junk-orphan-model" })
        let names = AppModel.selectableModelNames(availableModels)
        #expect(!names.contains("junk-orphan-model"))
        #expect(names.contains("apple-speech-analyzer"))
    }

    @Test("selectableModels (the ModelInfo-returning form TranscriptionDefaultsPane's picker uses) drops the same orphan")
    func selectableModelsDropsOrphanToo() {
        let models = AppModel.selectableModels([
            info("openai_whisper-large-v3_turbo"),
            info("apple-speech-analyzer"),
            info("parakeet-tdt-0.6b-v2-coreml"),
        ])
        #expect(models.map(\.name) == ["openai_whisper-large-v3_turbo", "apple-speech-analyzer"])
    }
}

@Suite("Model deletion")
struct ModelDeletionTests {
    private static let variant = "openai_whisper-large-v3_turbo"

    private func makeStore(withSupersededCopyOf variant: String) throws -> (ModelStore, URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDeletionTests-\(UUID().uuidString)", isDirectory: true)
        let superseded = root
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
        try FileManager.default.createDirectory(at: superseded, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: superseded.appendingPathComponent("model.mlmodelc"))
        return (ModelStore(modelsDirectory: root), root, superseded)
    }

    @Test("deleting a model whose only copy is the superseded one reports success")
    func leftoverOnlyDeletionSucceeds() throws {
        let (store, root, superseded) = try makeStore(withSupersededCopyOf: Self.variant)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: Never.self) { try AppModel.removeModelCopies(Self.variant, using: store) }
        #expect(FileManager.default.fileExists(atPath: superseded.path) == false)
    }

    @Test("deleting a model with no copies at all still reports the failure")
    func missingModelStillFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDeletionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelStore(modelsDirectory: root)

        #expect(throws: (any Error).self) { try AppModel.removeModelCopies(Self.variant, using: store) }
    }
}

@MainActor
@Suite("A finished download hands the phase back only when nothing is waiting on it")
struct DownloadCompletionPhaseTests {
    // Apple Speech is installed by definition, so the task reaches its completion path without a network call.
    private let installed = "apple-speech-analyzer"

    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("download-completion"))
    }

    private func waitUntil(timeoutMs: Int = 2_000, _ condition: @MainActor () -> Bool) async -> Bool {
        var elapsed = 0
        while elapsed < timeoutMs {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
            elapsed += 15
        }
        return condition()
    }

    @Test("a file run parked on the download keeps the phase the download was showing")
    func waitingFileRunKeepsThePhase() async {
        let model = makeModel()
        model.phase = .downloadingModel(name: installed, progress: 0)
        model.fileTranscribeTask = Task { try? await Task.sleep(for: .seconds(60)) }
        defer {
            model.fileTranscribeTask?.cancel()
            model.fileTranscribeTask = nil
        }

        #expect(model.downloadModel(installed))
        let wentIdle = await waitUntil(timeoutMs: 1_000) { model.phase == .idle }

        #expect(!wentIdle)
        #expect(model.phase == .downloadingModel(name: installed, progress: 1))
    }

    @Test("with nothing waiting on it the finished download hands the phase back")
    func lonelyDownloadReturnsToIdle() async {
        let model = makeModel()
        model.phase = .downloadingModel(name: installed, progress: 0)

        #expect(model.downloadModel(installed))

        #expect(await waitUntil { model.phase == .idle })
    }

    // The phases below are taken over mid-download, which no instant download can stage, so these
    // drive the completion step the task runs.
    @Test("a take that took the phase over is left alone")
    func recordingSurvivesTheDownload() {
        let model = makeModel()
        model.phase = .recording(source: .microphone)

        model.finishModelDownload()

        #expect(model.phase == .recording(source: .microphone))
    }

    @Test("a run that finished a beat before the download keeps its ready phase")
    func readyPhaseSurvivesTheDownload() {
        let model = makeModel()
        model.phase = .ready

        model.finishModelDownload()

        #expect(model.phase == .ready)
    }

    @Test("a progress tick arriving while a take owns the phase is dropped")
    func progressTickLeavesARecordingAlone() async {
        let model = makeModel()
        let tick = model.makeDownloadProgressHandler(for: installed)
        model.phase = .recording(source: .microphone)

        tick(0.5)
        let moved = await waitUntil(timeoutMs: 300) { model.phase != .recording(source: .microphone) }
        #expect(!moved)

        model.phase = .downloadingModel(name: installed, progress: 0)
        tick(0.75)

        #expect(await waitUntil { model.phase == .downloadingModel(name: installed, progress: 0.75) })
    }

    @Test("a progress tick while the download owns the phase moves the bar")
    func progressTickUpdatesTheDownload() async {
        let model = makeModel()
        let tick = model.makeDownloadProgressHandler(for: installed)
        model.phase = .downloadingModel(name: installed, progress: 0)

        tick(0.5)

        #expect(await waitUntil { model.phase == .downloadingModel(name: installed, progress: 0.5) })
    }

    @Test("a digest in flight paints no phase, so the finished download still hands it back")
    func duplicateDigestDoesNotHoldTheBar() {
        let model = makeModel()
        model.phase = .downloadingModel(name: installed, progress: 1)
        model.duplicateCheckTask = Task { try? await Task.sleep(for: .seconds(60)) }
        defer {
            model.duplicateCheckTask?.cancel()
            model.duplicateCheckTask = nil
        }

        model.finishModelDownload()

        #expect(model.phase == .idle)
    }

    @Test("a run parked in front of the engine keeps the bar it painted")
    func parkedRunKeepsItsOwnBar() {
        let model = makeModel()
        let parked = AppModel.Phase.downloadingModel(name: "openai_whisper-tiny", progress: 0)
        model.phase = parked
        model.fileTranscribeTask = Task { try? await Task.sleep(for: .seconds(60)) }
        defer {
            model.fileTranscribeTask?.cancel()
            model.fileTranscribeTask = nil
        }

        model.finishModelDownload()

        #expect(model.phase == parked)
    }

    @Test("a batch job holding the phase keeps it")
    func batchRunKeepsThePhase() {
        let model = makeModel()
        model.phase = .downloadingModel(name: installed, progress: 1)
        model.batchTask = Task { try? await Task.sleep(for: .seconds(60)) }
        defer {
            model.batchTask?.cancel()
            model.batchTask = nil
        }

        model.finishModelDownload()

        #expect(model.phase == .downloadingModel(name: installed, progress: 1))
    }
}
