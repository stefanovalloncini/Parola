import Foundation
import Testing
@testable import Parola
import ParolaCore

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
        UserDefaults(suiteName: "test-\(UUID())")!
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
