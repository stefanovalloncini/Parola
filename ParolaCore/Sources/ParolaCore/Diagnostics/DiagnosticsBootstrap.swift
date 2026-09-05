import Foundation

/// Installs the file sink for a process with nowhere else to own one — the CLI's long-running
/// commands, a one-shot under `PAROLA_DIAGNOSTICS=1`, and the standalone MCP binary. Core installs
/// nothing on its own: a frontend builds one of these, or no records are ever written.
public final class DiagnosticsBootstrap: Sendable {
    /// Where every Parola process writes its diagnostics: one shared folder, one file per process.
    public static var defaultDirectory: URL {
        let caches = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("Parola/diagnostics", isDirectory: true)
    }

    /// The file sink's floor. `PAROLA_LOG_LEVEL=debug` sends debug records to the file too.
    public static func minimumLevel(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LogLevel {
        environment["PAROLA_LOG_LEVEL"].flatMap(LogLevel.init(name:)) ?? .info
    }

    private let sink: FileDiagnosticsSink
    private let flushTask: Task<Void, Never>?

    /// `periodicFlush` bounds what a hard kill costs: without it only errors, a full buffer and the
    /// exit drain reach the file, so a long-running process would lose its breadcrumbs.
    public init(
        directory: URL = DiagnosticsBootstrap.defaultDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        periodicFlush: Bool,
        flushInterval: Duration = .seconds(2)
    ) {
        let sink = FileDiagnosticsSink(
            directory: directory,
            minimumLevel: Self.minimumLevel(environment: environment)
        )
        self.sink = sink
        // Best effort: the sink's retention sweep can log and it starts inside that initializer,
        // so installing right after it only usually catches the sweep's own notice.
        ParolaLog.install(sink)
        ParolaLog.info(.diagnostics, "diagnostics sink installed")
        flushTask = periodicFlush
            ? Task { [sink] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: flushInterval)
                    guard !Task.isCancelled else { return }
                    await sink.flush()
                }
            }
            : nil
        // Exit is the only hook a CLI has left once its command returns, and it cannot await.
        atexit { ParolaLog.flushSynchronously() }
    }

    public func stopPeriodicFlush() {
        flushTask?.cancel()
    }

    public func flush() async {
        await sink.flush()
    }

    public func flushSynchronously() {
        sink.flushSynchronously()
    }
}
