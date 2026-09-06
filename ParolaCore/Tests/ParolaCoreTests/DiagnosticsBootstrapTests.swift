import Foundation
import Testing
@testable import ParolaCore

@Suite("Diagnostics bootstrap", .serialized, .logFacade)
struct DiagnosticsBootstrapTests {
    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsBootstrapTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func sinkText(in directory: URL) throws -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(FileDiagnosticsSink.filePrefix) && name.hasSuffix(".jsonl") {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            if !text.isEmpty { return text }
        }
        return ""
    }

    private func waitForSinkText(in directory: URL, timeout: Duration = .seconds(5)) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let text = try sinkText(in: directory)
            if !text.isEmpty { return text }
            try await Task.sleep(for: .milliseconds(20))
        }
        return ""
    }

    @Test("PAROLA_LOG_LEVEL sets the file sink's floor, and garbage falls back to info")
    func minimumLevelFromEnvironment() {
        #expect(DiagnosticsBootstrap.minimumLevel(environment: ["PAROLA_LOG_LEVEL": "debug"]) == .debug)
        #expect(DiagnosticsBootstrap.minimumLevel(environment: ["PAROLA_LOG_LEVEL": "info"]) == .info)
        #expect(DiagnosticsBootstrap.minimumLevel(environment: ["PAROLA_LOG_LEVEL": "fault"]) == .fault)
        #expect(DiagnosticsBootstrap.minimumLevel(environment: ["PAROLA_LOG_LEVEL": "chatty"]) == .info)
        #expect(DiagnosticsBootstrap.minimumLevel(environment: [:]) == .info)
    }

    @Test("the installed sink takes records emitted through the facade")
    func installsTheSink() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootstrap = DiagnosticsBootstrap(directory: directory, environment: [:], periodicFlush: false)
        defer { ParolaLog.uninstall() }

        ParolaLog.info(.cli, "bootstrap probe")
        bootstrap.flushSynchronously()
        #expect(try sinkText(in: directory).contains("bootstrap probe"))
    }

    @Test("the periodic flush writes breadcrumbs nothing else would drain")
    func periodicFlushDrainsOnItsOwn() async throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootstrap = DiagnosticsBootstrap(
            directory: directory,
            environment: [:],
            periodicFlush: true,
            flushInterval: .milliseconds(20)
        )
        defer {
            bootstrap.stopPeriodicFlush()
            ParolaLog.uninstall()
        }

        let text = try await waitForSinkText(in: directory)
        #expect(text.contains("diagnostics sink installed"))
    }

    @Test("without the periodic flush an info record waits for a drain")
    func noPeriodicFlushLeavesTheBufferAlone() async throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootstrap = DiagnosticsBootstrap(directory: directory, environment: [:], periodicFlush: false)
        // The notice is buffered and flush() drains the sink directly; this keeps foreign records out.
        ParolaLog.uninstall()

        try await Task.sleep(for: .milliseconds(200))
        #expect(try sinkText(in: directory).isEmpty)

        await bootstrap.flush()
        #expect(try sinkText(in: directory).contains("diagnostics sink installed"))
    }
}
