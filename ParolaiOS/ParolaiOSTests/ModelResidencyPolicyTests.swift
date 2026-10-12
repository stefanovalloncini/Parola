import Foundation
import Testing
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
}
