import Foundation
import Testing
import ParolaCore
@testable import Parola

@Suite("ModelResidencyPolicy")
struct ModelResidencyPolicyTests {
    @Test("the phone keeps a model two minutes, well under the shared ten")
    func idleTimeout() {
        #expect(ModelResidencyPolicy.idleTimeout == .seconds(120))
        #expect(ModelResidencyPolicy.idleTimeoutSeconds == 120)
    }

    @Test(
        "models are released on background only while nothing is running",
        arguments: [
            (TranscriptionCoordinator.Phase.idle, true),
            (.failed(message: "x"), true),
            (.downloadingModel(name: "m", progress: 0.5), false),
            (.loadingModel(name: "m"), false),
            (.transcribing(file: URL(fileURLWithPath: "/tmp/a.wav")), false),
            (.recording, false),
        ]
    )
    func releaseGate(phase: TranscriptionCoordinator.Phase, releases: Bool) {
        #expect(ModelResidencyPolicy.releasesOnBackground(phase: phase) == releases)
    }

    @Test("releasing from an idle coordinator completes")
    @MainActor
    func idleReleaseCompletes() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("parola-resid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let coord = TranscriptionCoordinator(
            library: LibraryStore(libraryURL: tmp),
            settings: UserSettings(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        )
        await coord.releaseModelsInBackground()
        #expect(coord.phase == .idle)
    }
}
