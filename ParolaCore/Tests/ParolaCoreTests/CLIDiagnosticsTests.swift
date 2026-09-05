import Foundation
import Testing
@testable import ParolaCore
@testable import parola

@Suite("CLI diagnostics policy")
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

    @Test func levelComesFromTheEnvironment() {
        #expect(CLIDiagnostics.minimumLevel(environment: [:]) == .info)
        #expect(CLIDiagnostics.minimumLevel(environment: ["PAROLA_LOG_LEVEL": "debug"]) == .debug)
        #expect(CLIDiagnostics.minimumLevel(environment: ["PAROLA_LOG_LEVEL": "fault"]) == .fault)
        #expect(CLIDiagnostics.minimumLevel(environment: ["PAROLA_LOG_LEVEL": "chatty"]) == .info)
    }
}
