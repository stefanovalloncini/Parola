import Foundation
import ParolaCore

extension ParolaAutomationServer {
    func peopleCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "assignSpeaker",
                area: .transcript,
                summary: "Assigns a speaker label in the open transcript to a person, creating them when the name is new. Every segment carrying the label takes the person's name. Replies {speakerLabel, person, speakerAssignments}.",
                kind: .mutating,
                args: [
                    .init(name: "speakerLabel", kind: .string(), required: true, summary: "Speaker label as the segments carry it"),
                    .init(name: "personName", kind: .string(), required: true, summary: "Who that speaker is"),
                ],
                handler: { args, ctx in
                    let label = try args.string("speakerLabel").trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = try args.string("personName").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !label.isEmpty else {
                        throw AutomationError.invalidArgs(field: "speakerLabel", reason: "must not be blank")
                    }
                    guard !name.isEmpty else {
                        throw AutomationError.invalidArgs(field: "personName", reason: "must not be blank")
                    }
                    guard let transcript = ctx.model.transcript else {
                        throw AutomationError.precondition("no transcript is open")
                    }
                    guard transcript.uniqueSpeakers.contains(label) else {
                        throw AutomationError.notFound(kind: "speaker", id: label)
                    }
                    await ctx.model.assignSpeaker(label: label, toNewPersonNamed: name)
                    guard let person = await ctx.model.peopleStore.person(named: name) else {
                        throw AutomationError.internal("the person was not recorded")
                    }
                    return .object([
                        "speakerLabel": .string(person.name),
                        "person": Self.personState(person, usageCount: ctx.model.usageCount(of: person)),
                        "speakerAssignments": Self.speakerAssignmentsState(ctx.model),
                    ])
                }
            ),

            AutomationCommand(
                name: "listPeople",
                area: .library,
                summary: "The people directory: id, name, usageCount and colorIndex, most used first.",
                kind: .sync,
                handler: { _, ctx in
                    .object(["people": Self.peopleState(ctx.model)])
                }
            ),

            AutomationCommand(
                name: "setPersonFilter",
                area: .library,
                summary: "Filters the library list to one person, the way a PEOPLE sidebar row does. Pass no id, or null, to clear it.",
                kind: .mutating,
                args: [
                    .init(name: "personID", kind: .string(), required: false, summary: "Person id from listPeople; null clears the filter"),
                ],
                handler: { args, ctx in
                    guard let raw = args.rawValue("personID"), raw != .null else {
                        ctx.model.setPersonFilter(nil)
                        return .object(["personFilter": .null, "entryCount": .int(ctx.model.libraryEntries.count)])
                    }
                    guard case .string(let text) = raw, let id = UUID(uuidString: text) else {
                        throw AutomationError.invalidArgs(field: "personID", reason: "must be a UUID or null")
                    }
                    guard ctx.model.person(id: id) != nil else {
                        throw AutomationError.notFound(kind: "person", id: text)
                    }
                    ctx.model.setPersonFilter(id)
                    return .object([
                        "personFilter": .string(id.uuidString),
                        "entryCount": .int(ctx.model.entries(withPerson: id).count),
                    ])
                }
            ),
        ]
    }

    static func personState(_ person: Person, usageCount: Int) -> AutomationValue {
        .object([
            "id": .string(person.id.uuidString),
            "name": .string(person.name),
            "usageCount": .int(usageCount),
            "colorIndex": .int(person.colorIndex),
        ])
    }

    static func peopleState(_ model: AppModel) -> AutomationValue {
        .array(model.peopleByUse.map { personState($0, usageCount: model.usageCount(of: $0)) })
    }

    /// The open entry's map, as label → person id.
    static func speakerAssignmentsState(_ model: AppModel) -> AutomationValue {
        .object(model.speakerAssignments.mapValues { .string($0.uuidString) })
    }
}
