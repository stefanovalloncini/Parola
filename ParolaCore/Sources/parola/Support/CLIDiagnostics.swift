import Foundation
import os
import ParolaCore

/// Which commands get a diagnostics sink. Long-running ones always do; a one-shot only under
/// `PAROLA_DIAGNOSTICS=1`, so scripted runs do not accrete files.
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
        installed.withLock { $0 = bootstrap }
    }

    static func flush() async {
        await ParolaLog.flush()
    }
}
