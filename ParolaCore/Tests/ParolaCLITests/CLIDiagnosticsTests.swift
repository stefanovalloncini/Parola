import Foundation
import Testing
import ParolaCore
@testable import parola

@Suite("CLI diagnostics policy", .serialized, .logFacade)
struct CLIDiagnosticsTests {
    @Test func longRunningCommandsAlwaysInstall() {
        #expect(CLIDiagnostics.shouldInstall(alwaysOn: true, environment: [:]))
        #expect(CLIDiagnostics.shouldInstall(alwaysOn: true, environment: ["PAROLA_DIAGNOSTICS": "0"]))
    }

    @Test func oneShotsInstallOnlyUnderTheEnvironmentVariable() {
        #expect(!CLIDiagnostics.shouldInstall(alwaysOn: false, environment: [:]))
        #expect(CLIDiagnostics.shouldInstall(alwaysOn: false, environment: ["PAROLA_DIAGNOSTICS": "1"]))
        #expect(!CLIDiagnostics.shouldInstall(alwaysOn: false, environment: ["PAROLA_DIAGNOSTICS": "0"]))
        #expect(!CLIDiagnostics.shouldInstall(alwaysOn: false, environment: ["PAROLA_DIAGNOSTICS": "yes"]))
    }

    private func sinkText(in directory: URL) -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(FileDiagnosticsSink.filePrefix) && name.hasSuffix(".jsonl") {
            if let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) {
                return text
            }
        }
        return ""
    }

    /// `flush()` must drain the bootstrap it installed, not whatever sink is globally installed later.
    @Test func flushDrainsItsOwnBootstrapEvenAfterAForeignSinkTakesOver() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-cli-diagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        CLIDiagnostics.installIfWanted(
            alwaysOn: false, environment: ["PAROLA_DIAGNOSTICS": "1"], directory: directory
        )
        ParolaLog.info(.cli, "cli diagnostics flush test")

        let foreign = CapturingDiagnosticsSink()
        ParolaLog.install(foreign)
        defer { ParolaLog.uninstall() }

        await CLIDiagnostics.flush()

        #expect(sinkText(in: directory).contains("cli diagnostics flush test"))
    }
}
