import Foundation
import Testing
@testable import Parola

@Suite("StatusBanner copy")
struct StatusBannerTests {
    @Test(
        "banner copy for each phase",
        arguments: [
            (TranscriptionCoordinator.Phase.idle, nil),
            (.recording, nil),
            (.downloadingModel(name: "openai_whisper-tiny", progress: 0.42), "Downloading Whisper Tiny · 42%"),
            (.loadingModel(name: "openai_whisper-tiny"), "Loading Whisper Tiny…"),
            (.downloadingModel(name: "made-up-model-id", progress: 0.5), "Downloading made-up-model-id · 50%"),
            (.transcribing(file: URL(fileURLWithPath: "/tmp/clip.wav")), "Transcribing clip.wav…"),
            (.failed(message: "no model"), "no model"),
        ] as [(TranscriptionCoordinator.Phase, String?)]
    )
    func copy(for phase: TranscriptionCoordinator.Phase, expected: String?) {
        #expect(StatusBannerCopy.text(for: phase) == expected)
    }

    @Test(
        "isError is true only for failed phase",
        arguments: [
            (TranscriptionCoordinator.Phase.idle, false),
            (.recording, false),
            (.downloadingModel(name: "x", progress: 0.1), false),
            (.loadingModel(name: "x"), false),
            (.transcribing(file: URL(fileURLWithPath: "/tmp/a.wav")), false),
            (.failed(message: "boom"), true),
        ] as [(TranscriptionCoordinator.Phase, Bool)]
    )
    func errorFlag(for phase: TranscriptionCoordinator.Phase, expected: Bool) {
        #expect(StatusBannerCopy.isError(for: phase) == expected)
    }
}
