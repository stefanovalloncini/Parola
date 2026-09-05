import Foundation
import ParolaCore

@MainActor
final class DiagnosticsInstaller {
    /// Set at launch so the terminate barrier in `AppDelegate` can reach the sink it installed.
    static var current: DiagnosticsInstaller?

    static var defaultDirectory: URL {
        let caches = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("Parola/diagnostics", isDirectory: true)
    }

    nonisolated let directory: URL
    private nonisolated let sink: FileDiagnosticsSink
    private var flushTask: Task<Void, Never>?

    init(
        directory: URL = DiagnosticsInstaller.defaultDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        flushInterval: Duration = .seconds(2)
    ) {
        self.directory = directory
        let sink = FileDiagnosticsSink(
            directory: directory,
            minimumLevel: Self.minimumLevel(environment: environment)
        )
        self.sink = sink
        // Best effort: the sink's retention sweep can log and it starts inside that initializer,
        // so installing right after it only usually catches the sweep's own notice.
        ParolaLog.install(sink)
        ParolaLog.info(.appLifecycle, "diagnostics sink installed")
        flushTask = Task { [sink] in
            while !Task.isCancelled {
                try? await Task.sleep(for: flushInterval)
                guard !Task.isCancelled else { return }
                await sink.flush()
            }
        }
    }

    nonisolated static func minimumLevel(environment: [String: String]) -> LogLevel {
        environment["PAROLA_LOG_LEVEL"].flatMap(LogLevel.init(name:)) ?? .info
    }

    func stopPeriodicFlush() {
        flushTask?.cancel()
        flushTask = nil
    }

    /// Runs inside the terminate barrier, which blocks the main thread, so it must not hop to it.
    nonisolated func flushForTermination() async {
        await sink.flush()
    }
}
