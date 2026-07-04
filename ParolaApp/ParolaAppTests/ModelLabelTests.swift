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
