import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@Suite("Diagnostics installer", .serialized, .logFacade)
struct DiagnosticsInstallerTests {
    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsInstallerTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func waitForSinkFile(in directory: URL, timeout: Duration = .seconds(5)) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where name.hasPrefix("parola-") && name.hasSuffix(".jsonl") {
                let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
                if !text.isEmpty { return text }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("no diagnostics file was written")
        return ""
    }

    @Test("PAROLA_LOG_LEVEL sets the file sink's floor, and garbage falls back to info")
    func minimumLevelFromEnvironment() {
        #expect(DiagnosticsInstaller.minimumLevel(environment: ["PAROLA_LOG_LEVEL": "debug"]) == .debug)
        #expect(DiagnosticsInstaller.minimumLevel(environment: ["PAROLA_LOG_LEVEL": "info"]) == .info)
        #expect(DiagnosticsInstaller.minimumLevel(environment: ["PAROLA_LOG_LEVEL": "fault"]) == .fault)
        #expect(DiagnosticsInstaller.minimumLevel(environment: ["PAROLA_LOG_LEVEL": "chatty"]) == .info)
        #expect(DiagnosticsInstaller.minimumLevel(environment: [:]) == .info)
    }

    @MainActor
    @Test("a unit-test host installs no sink, whatever the bootstrap asks for")
    func testHostInstallsNoSink() {
        #expect(DiagnosticsInstaller.installIfWanted(
            sideEffects: BootstrapSideEffect.all,
            environment: ["XCTestConfigurationFilePath": "/tmp/whatever.xctestconfiguration"]
        ) == nil)
        #expect(DiagnosticsInstaller.installIfWanted(
            sideEffects: BootstrapSideEffect.testing, environment: [:]
        ) == nil)

        let installer = DiagnosticsInstaller.installIfWanted(sideEffects: AppBootstrap.normal.sideEffects)
        // Only reached if the guard regressed, and then it must not leave a sink writing into the
        // user's own diagnostics store for the rest of the run.
        if let installer {
            installer.stopPeriodicFlush()
            DiagnosticsInstaller.current = nil
            ParolaLog.uninstall()
        }
        #expect(installer == nil)
    }

    @MainActor
    @Test("the installed sink takes records emitted through the facade")
    func installsTheSink() async throws {
        let directory = scratchDirectory()
        let installer = DiagnosticsInstaller(directory: directory, environment: [:])
        defer {
            installer.stopPeriodicFlush()
            ParolaLog.uninstall()
        }

        ParolaLog.error(.appLifecycle, "installer test record")
        await ParolaLog.flush()

        let text = try await waitForSinkFile(in: directory)
        #expect(text.contains("installer test record"))
    }

    @MainActor
    @Test("the periodic flush writes the launch record without waiting for a full buffer")
    func periodicFlushWritesTheLaunchRecord() async throws {
        let directory = scratchDirectory()
        let installer = DiagnosticsInstaller(
            directory: directory,
            environment: [:],
            flushInterval: .milliseconds(20)
        )
        defer {
            installer.stopPeriodicFlush()
            ParolaLog.uninstall()
        }

        let text = try await waitForSinkFile(in: directory)
        #expect(text.contains("diagnostics sink installed"))
    }

    @MainActor
    @Test("the debug floor lets debug records through")
    func debugFloorKeepsDebugRecords() async throws {
        let directory = scratchDirectory()
        let installer = DiagnosticsInstaller(
            directory: directory,
            environment: ["PAROLA_LOG_LEVEL": "debug"]
        )
        defer {
            installer.stopPeriodicFlush()
            ParolaLog.uninstall()
        }

        ParolaLog.debug(.appLifecycle, "installer debug record")
        await installer.flushForTermination()

        let text = try await waitForSinkFile(in: directory)
        #expect(text.contains("installer debug record"))
    }
}
