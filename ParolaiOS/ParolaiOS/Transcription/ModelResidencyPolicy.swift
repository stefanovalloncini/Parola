import Foundation

/// A phone's jetsam limit makes the shared 600 s residency too long for a turbo model; two minutes still spans back-to-back takes.
enum ModelResidencyPolicy {
    static let idleTimeout: Duration = .seconds(120)
    static var idleTimeoutSeconds: TimeInterval { TimeInterval(idleTimeout.components.seconds) }

    static func releasesOnBackground(phase: TranscriptionCoordinator.Phase) -> Bool {
        switch phase {
        case .idle, .failed: true
        case .downloadingModel, .loadingModel, .transcribing, .recording, .finishing: false
        }
    }
}
