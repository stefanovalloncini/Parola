import Foundation
import ParolaCore

@MainActor
final class DiagnosticsInstaller {
    /// Set at launch so the terminate barrier in `AppDelegate` can reach the sink it installed.
    static var current: DiagnosticsInstaller?

    static var defaultDirectory: URL { DiagnosticsBootstrap.defaultDirectory }

    nonisolated let directory: URL
    private nonisolated let bootstrap: DiagnosticsBootstrap

    init(
        directory: URL = DiagnosticsInstaller.defaultDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        flushInterval: Duration = .seconds(2)
    ) {
        self.directory = directory
        // The bootstrap also registers an atexit drain, which backs up the 2s terminate barrier
        // when it runs out of time; `stopPeriodicFlush` runs before that barrier, so they never race.
        self.bootstrap = DiagnosticsBootstrap(
            directory: directory,
            environment: environment,
            periodicFlush: true,
            flushInterval: flushInterval
        )
    }

    /// A unit-test host must not install the sink: seeded failures and mock records would land in
    /// the store the user exports to support, and the budget trim would evict their real records.
    @discardableResult
    static func installIfWanted(
        sideEffects: Set<BootstrapSideEffect>,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DiagnosticsInstaller? {
        guard sideEffects.contains(.diagnosticsLog),
              environment["XCTestConfigurationFilePath"] == nil
        else { return nil }
        let installer = DiagnosticsInstaller(environment: environment)
        current = installer
        return installer
    }

    nonisolated static func minimumLevel(environment: [String: String]) -> LogLevel {
        DiagnosticsBootstrap.minimumLevel(environment: environment)
    }

    func stopPeriodicFlush() {
        bootstrap.stopPeriodicFlush()
    }

    /// Runs inside the terminate barrier, which blocks the main thread, so it must not hop to it.
    nonisolated func flushForTermination() async {
        await bootstrap.flush()
    }

    nonisolated func startNewFile() async {
        await bootstrap.startNewFile()
    }
}
