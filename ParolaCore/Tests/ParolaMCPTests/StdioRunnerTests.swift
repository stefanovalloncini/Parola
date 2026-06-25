import Foundation
import Testing
@testable import ParolaMCP

@Suite("StdioRunner parse-error id recovery")
struct StdioRunnerTests {
    private func recover(_ raw: String) -> JSONRPCID? {
        StdioRunner.recoverRequestID(from: Data(raw.utf8))
    }

    @Test("valid JSON missing 'method' still surfaces the int envelope id")
    func recoversIntID() {
        #expect(recover(#"{"jsonrpc":"2.0","id":99,"foo":"bar"}"#) == .int(99))
    }

    @Test("string ids round-trip through the second pass")
    func recoversStringID() {
        #expect(recover(#"{"jsonrpc":"2.0","id":"abc"}"#) == .string("abc"))
    }

    @Test("truncated/unparseable JSON yields nil — id MUST be null on a parse error")
    func truncatedYieldsNil() {
        #expect(recover(#"{"jsonrpc":"2.0","id":99,"method":"initialize""#) == nil)
        #expect(recover("this is not json at all") == nil)
    }

    @Test("valid JSON with no id field yields nil")
    func noIDYieldsNil() {
        #expect(recover(#"{"jsonrpc":"2.0","method":"x"}"#) == nil)
    }
}
