import Foundation
import Testing
import ParolaTestSupport
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

    @Test("the deferred flush writes breadcrumbs nothing else would drain")
    func periodicFlushDrainsOnItsOwn() async throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootstrap = DiagnosticsBootstrap(
            directory: directory,
            environment: [:],
            periodicFlush: true,
            flushInterval: .milliseconds(40)
        )
        defer {
            bootstrap.stopPeriodicFlush()
            ParolaLog.uninstall()
        }
        #expect(bootstrap.hasPeriodicFlush)

        let deadline = ContinuousClock.now + .seconds(5)
        var text = ""
        while ContinuousClock.now < deadline {
            text = (try? sinkText(in: directory)) ?? ""
            if text.contains("diagnostics sink installed") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(text.contains("diagnostics sink installed"))

        ParolaLog.info(.cli, "second breadcrumb")
        let again = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < again {
            text = (try? sinkText(in: directory)) ?? ""
            if text.contains("second breadcrumb") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(text.contains("second breadcrumb"))
    }

    @Test("without the periodic flush no flush task runs and flush() drains the notice")
    func noPeriodicFlushLeavesTheBufferAlone() async throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootstrap = DiagnosticsBootstrap(directory: directory, environment: [:], periodicFlush: false)
        // flush() drains the sink directly; uninstalling first keeps foreign records out of it.
        ParolaLog.uninstall()
        #expect(!bootstrap.hasPeriodicFlush)

        await bootstrap.flush()
        #expect(try sinkText(in: directory).contains("diagnostics sink installed"))
    }
}
