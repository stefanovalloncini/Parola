import Foundation
import Testing

@Suite("CLI diagnostics install policy", .serialized, .enabled(if: parolaBinaryURL != nil))
struct CLIDiagnosticsProcessTests {
    @Test func oneShotWritesNothingByDefault() throws {
        try withTemporaryHome { home, environment in
            let run = try runParola(["models", "list"], environment: environment)
            #expect(run.status == 0)
            #expect(diagnosticsFiles(in: home).isEmpty)
        }
    }

    @Test func oneShotWritesUnderTheEnvironmentVariable() throws {
        try withTemporaryHome { home, environment in
            var environment = environment
            environment["PAROLA_DIAGNOSTICS"] = "1"
            let run = try runParola(["models", "list"], environment: environment)
            #expect(run.status == 0)
            #expect(diagnosticsFiles(in: home).count == 1)
        }
    }
}
