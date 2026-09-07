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

    @Test("the youtube pseudo-id falls back to its raw string")
    func youtubePseudoIDFallsBack() {
        #expect(AppModel.modelLabel("youtube") == "youtube")
    }

    @Test("an unknown model id falls back to its raw string")
    func unknownIDFallsBack() {
        #expect(AppModel.modelLabel("made-up-model-id") == "made-up-model-id")
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
    @MainActor func modelTracksStages() {
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
