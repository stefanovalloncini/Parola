import Foundation
import ParolaCore

/// Installs the CLI's diagnostics sink and gets its records to disk. Long-running commands always
/// install one; a one-shot only does under `PAROLA_DIAGNOSTICS=1`, so scripted runs stay clean.
enum CLIDiagnostics {
    static func shouldInstall(alwaysOn: Bool, environment: [String: String]) -> Bool {
        alwaysOn || environment["PAROLA_DIAGNOSTICS"] == "1"
    }

    static func minimumLevel(environment: [String: String]) -> LogLevel {
        environment["PAROLA_LOG_LEVEL"].flatMap(LogLevel.init(name:)) ?? .info
    }

    static func installIfWanted(
        alwaysOn: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        directory: URL = FileDiagnosticsSink.defaultDirectory
    ) {
        guard shouldInstall(alwaysOn: alwaysOn, environment: environment) else { return }
        let sink = FileDiagnosticsSink(
            directory: directory,
            minimumLevel: minimumLevel(environment: environment)
        )
        ParolaLog.install(sink)
        ParolaLog.info(.cli, "diagnostics sink installed")
        installExitFlush()
        guard alwaysOn else { return }
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await ParolaLog.flush()
            }
        }
    }

    static func flush() async {
        await ParolaLog.flush()
    }

    /// ArgumentParser hands back no hook once a subcommand's `run()` returns, so without this a
    /// one-shot command's buffered records die with the process.
    private static func installExitFlush() {
        atexit {
            let drained = DispatchSemaphore(value: 0)
            Task {
                await ParolaLog.flush()
                drained.signal()
            }
            _ = drained.wait(timeout: .now() + 2)
        }
    }
}
