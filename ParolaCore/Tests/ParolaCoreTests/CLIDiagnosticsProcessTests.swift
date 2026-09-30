import Foundation
import Testing

@Suite("CLI diagnostics install policy", .serialized, .enabled(if: parolaBinaryURL != nil))
struct CLIDiagnosticsProcessTests {
    @Test func oneShotWritesNothingByDefault() async throws {
        try await withTemporaryHome { home, environment in
            let run = try await runParola(["models", "list"], environment: environment)
            #expect(run.status == 0)
            #expect(diagnosticsFiles(in: home).isEmpty)
        }
    }

    @Test func oneShotWritesUnderTheEnvironmentVariable() async throws {
        try await withTemporaryHome { home, environment in
            var environment = environment
            environment["PAROLA_DIAGNOSTICS"] = "1"
            let run = try await runParola(["models", "list"], environment: environment)
            #expect(run.status == 0)
            #expect(diagnosticsFiles(in: home).count == 1)
        }
    }
}
