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

    @Test("the periodic flush writes breadcrumbs nothing else would drain")
    func periodicFlushDrainsOnItsOwn() async throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let bootstrap = DiagnosticsBootstrap(
            directory: directory,
            environment: [:],
            periodicFlush: true,
            flushInterval: .seconds(2),
            clock: clock
        )
        defer {
            bootstrap.stopPeriodicFlush()
            ParolaLog.uninstall()
        }
        #expect(bootstrap.hasPeriodicFlush)

        await clock.waitForSleeper()
        clock.advance(by: .seconds(2))
        // The loop sleeps again only once its flush has returned.
        await clock.waitForSleeper()
        #expect(try sinkText(in: directory).contains("diagnostics sink installed"))
    }

    @Test("without the periodic flush nothing drains until asked")
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
