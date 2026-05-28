import Foundation
import Testing
@testable import Parola

@Suite("AutomationValue")
struct AutomationValueTests {

    @Test("null round-trips through jsonObject")
    func nullRoundTrip() {
        let value = AutomationValue.null
        let restored = AutomationValue(value.jsonObject)
        #expect(restored == .null)
        #expect(value.jsonObject is NSNull)
    }

    @Test("bool round-trips through jsonObject")
    func boolRoundTrip() {
        for original in [AutomationValue.bool(true), .bool(false)] {
            let restored = AutomationValue(original.jsonObject)
            #expect(restored == original)
        }
    }

    @Test("int round-trips through jsonObject")
    func intRoundTrip() {
        let original = AutomationValue.int(42)
        let restored = AutomationValue(original.jsonObject)
        #expect(restored == .int(42))
    }

    @Test("double round-trips through jsonObject")
    func doubleRoundTrip() {
        let original = AutomationValue.double(3.14)
        let restored = AutomationValue(original.jsonObject)
        #expect(restored == .double(3.14))
    }

    @Test("string round-trips through jsonObject")
    func stringRoundTrip() {
        let original = AutomationValue.string("hello world")
        let restored = AutomationValue(original.jsonObject)
        #expect(restored == .string("hello world"))
    }

    @Test("array of primitives round-trips through jsonObject")
    func arrayRoundTrip() {
        let original = AutomationValue.array([
            .string("a"),
            .int(1),
            .bool(true),
            .null,
        ])
        let restored = AutomationValue(original.jsonObject)
        #expect(restored == original)
    }

    @Test("nested object round-trips through jsonObject")
    func nestedObjectRoundTrip() {
        let original = AutomationValue.object([
            "name": .string("entry"),
            "count": .int(3),
            "tags": .array([.string("a"), .string("b")]),
            "meta": .object([
                "ok": .bool(true),
                "ratio": .double(0.5),
            ]),
        ])
        let restored = AutomationValue(original.jsonObject)
        #expect(restored == original)
    }

    @Test("initializer maps NSNull to .null")
    func initFromNSNull() {
        #expect(AutomationValue(NSNull()) == .null)
        #expect(AutomationValue(nil as Any?) == .null)
    }

    @Test("initializer maps Swift Bool to .bool")
    func initFromBool() {
        #expect(AutomationValue(true) == .bool(true))
        #expect(AutomationValue(false) == .bool(false))
    }

    @Test("initializer maps Int and Int64 to .int")
    func initFromInt() {
        #expect(AutomationValue(7) == .int(7))
        #expect(AutomationValue(Int64(123_456)) == .int(123_456))
    }

    @Test("initializer maps Double and Float to .double")
    func initFromDouble() {
        #expect(AutomationValue(1.5) == .double(1.5))
        #expect(AutomationValue(Float(2.25)) == .double(2.25))
    }

    @Test("initializer maps String to .string")
    func initFromString() {
        #expect(AutomationValue("hi") == .string("hi"))
    }

    @Test("initializer maps [Any] to .array")
    func initFromArray() {
        let value = AutomationValue([1, "two", true] as [Any])
        #expect(value == .array([.int(1), .string("two"), .bool(true)]))
    }

    @Test("initializer maps [String: Any] to .object")
    func initFromObject() {
        let value = AutomationValue(["k": "v", "n": 9] as [String: Any])
        guard case .object(let dict) = value else {
            Issue.record("expected .object, got \(value)")
            return
        }
        #expect(dict["k"] == .string("v"))
        #expect(dict["n"] == .int(9))
    }

    @Test("NSNumber bool stays .bool")
    func nsNumberBool() {
        let value = AutomationValue(NSNumber(value: true))
        #expect(value == .bool(true))
    }

    @Test("NSNumber double stays .double")
    func nsNumberDouble() {
        let value = AutomationValue(NSNumber(value: 1.25))
        #expect(value == .double(1.25))
    }

    @Test("NSNumber int stays .int")
    func nsNumberInt() {
        let value = AutomationValue(NSNumber(value: 42))
        #expect(value == .int(42))
    }

    @Test("NSNumber 0 and 1 decode as int, not bool")
    func nsNumberIntZeroOneNotBool() {
        #expect(AutomationValue(NSNumber(value: 0)) == .int(0))
        #expect(AutomationValue(NSNumber(value: 1)) == .int(1))
        #expect(AutomationValue(NSNumber(value: true)) == .bool(true))
        #expect(AutomationValue(NSNumber(value: false)) == .bool(false))
    }

    @Test("JSONSerialization wire values keep int / bool / double distinct")
    func wireRoundTripIntBoolDouble() throws {
        let data = Data(#"{"i":0,"j":1,"b":true,"d":2.0}"#.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(AutomationValue(obj["i"]) == .int(0))
        #expect(AutomationValue(obj["j"]) == .int(1))
        #expect(AutomationValue(obj["b"]) == .bool(true))
        #expect(AutomationValue(obj["d"]) == .double(2.0))
    }
}
