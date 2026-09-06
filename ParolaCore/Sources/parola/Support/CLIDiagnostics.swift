import Foundation
import os
import ParolaCore

/// Long-running commands always get a diagnostics sink; a one-shot only under `PAROLA_DIAGNOSTICS=1`.
enum CLIDiagnostics {
    private static let installed = OSAllocatedUnfairLock<DiagnosticsBootstrap?>(initialState: nil)

    static func shouldInstall(alwaysOn: Bool, environment: [String: String]) -> Bool {
        alwaysOn || environment["PAROLA_DIAGNOSTICS"] == "1"
    }

    static func installIfWanted(
        alwaysOn: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        directory: URL = DiagnosticsBootstrap.defaultDirectory
    ) {
        guard shouldInstall(alwaysOn: alwaysOn, environment: environment) else { return }
        let bootstrap = DiagnosticsBootstrap(
            directory: directory,
            environment: environment,
            periodicFlush: alwaysOn
        )
        let previous = installed.withLock {
            let old = $0
            $0 = bootstrap
            return old
        }
        previous?.stopPeriodicFlush()
    }

    static func flush() async {
        if let bootstrap = installed.withLock({ $0 }) {
            await bootstrap.flush()
        } else {
            await ParolaLog.flush()
        }
    }
}
