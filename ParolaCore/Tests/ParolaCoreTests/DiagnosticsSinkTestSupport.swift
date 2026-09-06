import Foundation
import Testing
@testable import ParolaCore

extension FileDiagnosticsSink {
    /// Waits for the install-time sweep (runs on a background queue) so fixtures don't race it.
    func waitForInstallSweep(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if completedSweeps > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the install-time sweep never finished")
    }
}
