import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaDictation

@MainActor
@Suite("Bridge waiter commands")
struct WaiterTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        temporaryDefaults()
    }

    private func makeRig() throws -> (AppModel, ParolaAutomationServer, AutomationContext, [String: AutomationCommand]) {
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("waiter"))
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let commands = Dictionary(uniqueKeysWithValues: server.waitCommands().map { ($0.name, $0) })
        return (model, server, context, commands)
    }

    private func matched(_ value: AutomationValue) -> Bool? {
        guard case .object(let dict) = value, case .bool(let flag) = dict["matched"] ?? .null else {
            return nil
        }
        return flag
    }

    private func timedOut(_ value: AutomationValue) -> Bool? {
        guard case .object(let dict) = value, case .bool(let flag) = dict["timedOut"] ?? .null else {
            return nil
        }
        return flag
    }

    @Test("waitForPhase resolves once model.phase moves to the target")
    func waitForPhaseResolves() async throws {
        let (model, server, context, commands) = try makeRig()
        let command = try #require(commands["waitForPhase"])
        let args = try command.validate(AutomationArgs([
            "phase": .string("ready"),
            "timeoutMs": .int(300),
        ]))

        let mutate = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20), clock: ContinuousClock())
            model.phase = .ready
        }

        let result = try await command.handler(args, context)
        await mutate.value
        withExtendedLifetime(server) {}

        #expect(matched(result) == true)
    }

    @Test("waitForRevision returns matched:false + timedOut:true when revision never reaches min")
    func waitForRevisionTimesOut() async throws {
        let (_, server, context, commands) = try makeRig()
        let command = try #require(commands["waitForRevision"])
        let args = try command.validate(AutomationArgs([
            "min": .int(999_999),
            "timeoutMs": .int(80),
        ]))

        let result = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(matched(result) == false)
        #expect(timedOut(result) == true)
    }

    @Test("waitForLibraryCount resolves immediately when the predicate already holds")
    func waitForLibraryCountMatchesImmediately() async throws {
        let (_, server, context, commands) = try makeRig()
        let command = try #require(commands["waitForLibraryCount"])
        let args = try command.validate(AutomationArgs([
            "op": .string("=="),
            "count": .int(0),
            "timeoutMs": .int(50),
        ]))

        let result = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(matched(result) == true)
        #expect(timedOut(result) == nil)
    }

    @Test("waitForBatchEmpty returns matched:true while no jobs exist")
    func waitForBatchEmptyMatchesImmediately() async throws {
        let (_, server, context, commands) = try makeRig()
        let command = try #require(commands["waitForBatchEmpty"])
        let args = try command.validate(AutomationArgs([
            "timeoutMs": .int(50),
        ]))

        let result = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(matched(result) == true)
    }

    @Test("waitForDictationState resolves on the live coordinator state, not the settings toggle")
    func waitForDictationStateTracksLiveState() async throws {
        let (model, server, context, commands) = try makeRig()
        let command = try #require(commands["waitForDictationState"])

        // The live mirror is .listening while the settings toggle stays off — the old code
        // read the toggle and would never resolve here.
        model.dictationState = .listening
        let args = try command.validate(AutomationArgs([
            "state": .string("listening"),
            "timeoutMs": .int(400),
        ]))
        let result = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(matched(result) == true)
    }

    @Test("a waiter evaluates the predicate at least once even with a non-positive timeout")
    func waiterChecksPredicateOnZeroTimeout() async throws {
        let (_, server, context, commands) = try makeRig()
        let command = try #require(commands["waitForLibraryCount"])
        // Library is empty, so count == 0 already holds; with timeoutMs 0 the old
        // loop body never ran and reported a spurious timeout.
        let args = try command.validate(AutomationArgs([
            "op": .string("=="),
            "count": .int(0),
            "timeoutMs": .int(0),
        ]))
        let result = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(matched(result) == true)
    }

    @Test("waitForDictationState(listening) times out while the coordinator is idle")
    func waitForDictationStateIdleTimesOut() async throws {
        let (model, server, context, commands) = try makeRig()
        let command = try #require(commands["waitForDictationState"])

        model.dictationState = .idle
        let args = try command.validate(AutomationArgs([
            "state": .string("listening"),
            "timeoutMs": .int(120),
        ]))
        let result = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(matched(result) == false)
        #expect(timedOut(result) == true)
    }
}
