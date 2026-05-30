import Foundation
import Testing
@testable import Parola

@Suite("AutomationResponse")
struct AutomationResponseTests {

    private static func decode(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("success wraps a result with ok true and no error")
    func successShape() {
        let response = AutomationResponse.success(
            id: "req-1",
            command: "get_state",
            result: .object(["ready": .bool(true)]),
            serverVersion: 7,
            elapsedMs: 12
        )
        #expect(response.ok)
        #expect(response.id == "req-1")
        #expect(response.command == "get_state")
        #expect(response.result == .object(["ready": .bool(true)]))
        #expect(response.error == nil)
        #expect(response.serverVersion == 7)
        #expect(response.elapsedMs == 12)
    }

    @Test("failure carries the error wire payload and no result")
    func failureShape() {
        let response = AutomationResponse.failure(
            id: "req-2",
            command: "load_entry",
            error: .notFound(kind: "entry", id: "abc"),
            serverVersion: 3,
            elapsedMs: 4
        )
        #expect(response.ok == false)
        #expect(response.result == nil)
        #expect(response.error?.code == "NOT_FOUND")
        #expect(response.error?.message == "entry not found: abc")
        #expect(response.error?.details["id"] == .string("abc"))
    }

    @Test("encoded success JSON exposes the expected fields")
    func encodeSuccess() throws {
        let response = AutomationResponse.success(
            id: "id-1",
            command: "ping",
            result: .string("pong"),
            serverVersion: 2,
            elapsedMs: 9
        )
        let object = try Self.decode(AutomationResponseEncoder.encode(response))
        #expect(object["id"] as? String == "id-1")
        #expect(object["ok"] as? Bool == true)
        #expect(object["command"] as? String == "ping")
        #expect(object["result"] as? String == "pong")
        #expect(object["serverVersion"] as? Int == 2)
        #expect(object["elapsedMs"] as? Int == 9)
        #expect(object["error"] == nil)
    }

    @Test("encoded failure JSON nests the error code, message and details")
    func encodeFailure() throws {
        let response = AutomationResponse.failure(
            id: "id-2",
            command: "select_model",
            error: .invalidArgs(field: "name", reason: "must be a string"),
            serverVersion: 1,
            elapsedMs: 0
        )
        let object = try Self.decode(AutomationResponseEncoder.encode(response))
        #expect(object["ok"] as? Bool == false)
        #expect(object["result"] == nil)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "INVALID_ARGS")
        #expect(error["message"] as? String == "Invalid args for 'name': must be a string")
        let details = try #require(error["details"] as? [String: Any])
        #expect(details["field"] as? String == "name")
        #expect(details["reason"] as? String == "must be a string")
    }

    @Test("encoder does not escape forward slashes in string results")
    func encoderKeepsSlashes() throws {
        let response = AutomationResponse.success(
            id: "id-3",
            command: "open_app",
            result: .string("/tmp/clip.wav"),
            serverVersion: 1,
            elapsedMs: 1
        )
        let json = try #require(String(data: AutomationResponseEncoder.encode(response), encoding: .utf8))
        #expect(json.contains("/tmp/clip.wav"))
        #expect(json.contains("\\/") == false)
    }
}
