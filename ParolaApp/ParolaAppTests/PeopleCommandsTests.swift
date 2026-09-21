import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Bridge people commands")
struct PeopleCommandsTests {

    private func makeRig(_ label: String) throws -> (AppModel, ParolaAutomationServer, AutomationContext, [String: AutomationCommand]) {
        let bootstrap = AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL(label),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: SystemFilePicker(),
            enabledFeaturesOverride: Set(ParolaFeature.allCases),
            apiKeyStore: InMemoryAPIKeyStore()
        )
        let model = AppModel(bootstrap: bootstrap)
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let commands = Dictionary(uniqueKeysWithValues: server.peopleCommands().map { ($0.name, $0) })
        return (model, server, context, commands)
    }

    private func run(
        _ commands: [String: AutomationCommand],
        _ name: String,
        _ args: [String: AutomationValue] = [:],
        _ context: AutomationContext
    ) async throws -> AutomationValue {
        let command = try #require(commands[name])
        return try await command.handler(try command.validate(AutomationArgs(args)), context)
    }

    private func field(_ value: AutomationValue, _ key: String) throws -> AutomationValue {
        guard case .object(let fields) = value, let found = fields[key] else {
            throw AutomationError.notFound(kind: "field", id: key)
        }
        return found
    }

    @Test("assignSpeaker renames the label, creates the person and shows in getState")
    func assignSpeakerRoundTrip() async throws {
        let (model, server, context, commands) = try makeRig("peoplecmd")
        let entry = try await PeopleTestSupport.seed(model)
        try await PeopleTestSupport.open(model, entry: entry)

        let reply = try await run(
            commands, "assignSpeaker",
            ["speakerLabel": .string("SPEAKER_00"), "personName": .string("Ada")],
            context
        )

        #expect(try field(reply, "speakerLabel") == .string("Ada"))
        #expect(try field(field(reply, "person"), "name") == .string("Ada"))
        #expect(try field(field(reply, "person"), "usageCount") == .int(1))
        #expect(model.transcript?.segments.map(\.speaker) == ["Ada", "SPEAKER_01", "Ada"])

        let state = server.snapshotState()
        let person = try #require(model.people.first)
        #expect(try field(field(state, "speakerAssignments"), "Ada") == .string(person.id.uuidString))
        guard case .array(let people) = try field(state, "people") else {
            Issue.record("expected an array of people")
            return
        }
        #expect(try field(people[0], "colorIndex") == .int(person.colorIndex))
    }

    @Test("listPeople returns the directory most used first")
    func listPeople() async throws {
        let (model, server, context, commands) = try makeRig("peoplelist")
        await model.addPerson(named: "Ada")
        await model.addPerson(named: "Grace")
        await model.addPerson(named: "Grace")

        let reply = try await run(commands, "listPeople", [:], context)
        guard case .array(let people) = try field(reply, "people") else {
            Issue.record("expected an array of people")
            return
        }
        #expect(people.count == 2)
        #expect(try field(people[0], "name") == .string("Grace"))
        withExtendedLifetime(server) {}
    }

    @Test("assignSpeaker refuses a blank name, an unknown label and a closed transcript")
    func assignSpeakerRefusals() async throws {
        let (model, server, context, commands) = try makeRig("peoplerefuse")

        await #expect(throws: AutomationError.self) {
            _ = try await run(
                commands, "assignSpeaker",
                ["speakerLabel": .string("SPEAKER_00"), "personName": .string("Ada")],
                context
            )
        }

        let entry = try await PeopleTestSupport.seed(model)
        try await PeopleTestSupport.open(model, entry: entry)

        await #expect(throws: AutomationError.self) {
            _ = try await run(
                commands, "assignSpeaker",
                ["speakerLabel": .string("SPEAKER_00"), "personName": .string("   ")],
                context
            )
        }
        await #expect(throws: AutomationError.self) {
            _ = try await run(
                commands, "assignSpeaker",
                ["speakerLabel": .string("NOBODY"), "personName": .string("Ada")],
                context
            )
        }
        #expect(model.people.isEmpty)
        withExtendedLifetime(server) {}
    }

    @Test("setPersonFilter sets and clears the library filter")
    func setPersonFilter() async throws {
        let (model, server, context, commands) = try makeRig("peoplefilter")
        let entry = try await PeopleTestSupport.seed(model)
        try await PeopleTestSupport.open(model, entry: entry)
        await model.assignSpeaker(label: "SPEAKER_00", toNewPersonNamed: "Ada")
        let ada = try #require(model.people.first)

        let set = try await run(commands, "setPersonFilter", ["personID": .string(ada.id.uuidString)], context)
        #expect(model.personFilter == ada.id)
        #expect(try field(set, "entryCount") == .int(1))
        #expect(try field(server.snapshotState(), "personFilter") == .string(ada.id.uuidString))

        let cleared = try await run(commands, "setPersonFilter", [:], context)
        #expect(model.personFilter == nil)
        #expect(try field(cleared, "personFilter") == .null)
    }

    @Test("setPersonFilter refuses a malformed id and one nobody holds")
    func setPersonFilterRefusals() async throws {
        let (model, server, context, commands) = try makeRig("peoplefilterbad")

        await #expect(throws: AutomationError.self) {
            _ = try await run(commands, "setPersonFilter", ["personID": .string("not-a-uuid")], context)
        }
        await #expect(throws: AutomationError.self) {
            _ = try await run(commands, "setPersonFilter", ["personID": .string(UUID().uuidString)], context)
        }
        #expect(model.personFilter == nil)
        withExtendedLifetime(server) {}
    }
}
