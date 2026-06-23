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

    @Test("an unknown model id falls back to its raw string")
    func unknownIDFallsBack() {
        #expect(AppModel.modelLabel("made-up-model-id") == "made-up-model-id")
    }
}
