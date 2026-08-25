import Foundation
import Testing
@testable import ParolaCore

extension FileDiagnosticsSink {
    /// The install-time sweep runs on a background queue, so a test that seeds fixtures after
    /// construction has to wait for it or the two sweeps race over the same files.
    func waitForInstallSweep(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if completedSweeps > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the install-time sweep never finished")
    }
}
