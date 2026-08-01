import Foundation
import Testing
@testable import Parola

@MainActor
@Suite("AutomationCommand catalog + arg validation")
struct AutomationCommandRegistryTests {

    private func makeCommand(
        args: [AutomationCommand.Argument] = []
    ) -> AutomationCommand {
        AutomationCommand(
            name: "echo",
            area: .test,
            summary: "noop for tests",
            kind: .sync,
            args: args
        ) { _, _ in .null }
    }

    private var stringAndBool: [AutomationCommand.Argument] {
        [
            .init(name: "name", kind: .string(), required: true, summary: "name"),
            .init(name: "force", kind: .boolean, required: false, summary: "force", defaultValue: .bool(false)),
        ]
    }

    @Test("validate throws invalidArgs when a required arg is missing")
    func missingRequiredThrows() {
        let cmd = makeCommand(args: stringAndBool)
        do {
            _ = try cmd.validate(AutomationArgs())
            Issue.record("expected validate to throw")
        } catch let error as AutomationError {
            #expect(error.code == "INVALID_ARGS")
            #expect(error.details["field"] == .string("name"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("validate throws invalidArgs when a required arg has the wrong type")
    func wrongTypeThrows() {
        let cmd = makeCommand(args: stringAndBool)
        do {
            _ = try cmd.validate(AutomationArgs(["name": .int(7)]))
            Issue.record("expected validate to throw")
        } catch let error as AutomationError {
            #expect(error.code == "INVALID_ARGS")
            #expect(error.details["field"] == .string("name"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("validate applies the default value when an optional arg is absent")
    func optionalDefaultApplied() throws {
        let cmd = makeCommand(args: stringAndBool)
        let merged = try cmd.validate(AutomationArgs(["name": .string("entry")]))
        #expect(merged["force"] == .bool(false))
        #expect(merged["name"] == .string("entry"))
    }

    @Test("validate accepts a well-formed args dictionary")
    func acceptsCorrectShape() throws {
        let cmd = makeCommand(args: stringAndBool)
        let merged = try cmd.validate(AutomationArgs([
            "name": .string("entry"),
            "force": .bool(true),
        ]))
        #expect(merged["force"] == .bool(true))
        #expect(merged["name"] == .string("entry"))
    }

    @Test("string(enum:) rejects values not in the allowed set")
    func enumRejectsUnknown() {
        let cmd = makeCommand(args: [
            .init(
                name: "mode",
                kind: .string(enum: ["fast", "slow"]),
                required: true,
                summary: "mode"
            )
        ])
        do {
            _ = try cmd.validate(AutomationArgs(["mode": .string("medium")]))
            Issue.record("expected validate to throw")
        } catch let error as AutomationError {
            #expect(error.code == "INVALID_ARGS")
            #expect(error.details["field"] == .string("mode"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("string(enum:) accepts a value in the allowed set")
    func enumAcceptsKnown() throws {
        let cmd = makeCommand(args: [
            .init(
                name: "mode",
                kind: .string(enum: ["fast", "slow"]),
                required: true,
                summary: "mode"
            )
        ])
        let merged = try cmd.validate(AutomationArgs(["mode": .string("fast")]))
        #expect(merged["mode"] == .string("fast"))
    }

    @Test("invalidArgs maps to INVALID_ARGS with field + reason in details")
    func invalidArgsWire() {
        let error = AutomationError.invalidArgs(field: "id", reason: "missing required string")
        #expect(error.code == "INVALID_ARGS")
        #expect(error.details["field"] == .string("id"))
        #expect(error.details["reason"] == .string("missing required string"))
    }

    @Test("unknownCommand maps to UNKNOWN_COMMAND with the name in details")
    func unknownCommandWire() {
        let error = AutomationError.unknownCommand("foo")
        #expect(error.code == "UNKNOWN_COMMAND")
        #expect(error.details["command"] == .string("foo"))
    }

    @Test("precondition maps to PRECONDITION with empty details")
    func preconditionWire() {
        let error = AutomationError.precondition("no transcript")
        #expect(error.code == "PRECONDITION")
        #expect(error.details.isEmpty)
        #expect(error.message == "no transcript")
    }

    @Test("permission maps to PERMISSION with empty details")
    func permissionWire() {
        let error = AutomationError.permission("screen recording missing")
        #expect(error.code == "PERMISSION")
        #expect(error.details.isEmpty)
    }

    @Test("notFound maps to NOT_FOUND with kind + id in details")
    func notFoundWire() {
        let error = AutomationError.notFound(kind: "entry", id: "abc123")
        #expect(error.code == "NOT_FOUND")
        #expect(error.details["kind"] == .string("entry"))
        #expect(error.details["id"] == .string("abc123"))
    }

    @Test("internal maps to INTERNAL with empty details")
    func internalWire() {
        let error = AutomationError.internal("boom")
        #expect(error.code == "INTERNAL")
        #expect(error.details.isEmpty)
    }

    @Test("appDead maps to APP_DEAD with empty details")
    func appDeadWire() {
        let error = AutomationError.appDead("gone")
        #expect(error.code == "APP_DEAD")
        #expect(error.details.isEmpty)
    }

    @Test("timeout maps to TIMEOUT and stays distinct from PRECONDITION")
    func timeoutWire() {
        let error = AutomationError.timeout("main thread did not answer within 5.0s")
        #expect(error.code == "TIMEOUT")
        #expect(error.details.isEmpty)
        #expect(error.message == "main thread did not answer within 5.0s")
        #expect(error.code != AutomationError.precondition("x").code)
    }
}
