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

    /// `periodicFlush` bounds what a hard kill costs: without it only errors, a full buffer and the
    /// exit drain reach the file, so a long-running process would lose its breadcrumbs. The flush is
    /// armed by the first record into an empty buffer, so an idle process runs no timer at all.
    public init(
        directory: URL = DiagnosticsBootstrap.defaultDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        periodicFlush: Bool,
        flushInterval: Duration = .seconds(2)
    ) {
        let sink = FileDiagnosticsSink(
            directory: directory,
            minimumLevel: Self.minimumLevel(environment: environment),
            flushDelay: periodicFlush ? flushInterval : nil
        )
        self.sink = sink
        // Best effort: the sweep starts inside init, so this only usually catches its own notice.
        ParolaLog.install(sink)
        ParolaLog.info(.diagnostics, "diagnostics sink installed")
        // Exit is the only hook a CLI has left once its command returns, and it cannot await.
        atexit { ParolaLog.flushSynchronously() }
    }

    var hasPeriodicFlush: Bool { sink.hasDeferredFlush }

    public func stopPeriodicFlush() {
        sink.stopDeferredFlush()
    }

    public func flush() async {
        await sink.flush()
    }

    public func startNewFile() async {
        await sink.startNewFile()
    }

    public func flushSynchronously() {
        sink.flushSynchronously()
    }
}
