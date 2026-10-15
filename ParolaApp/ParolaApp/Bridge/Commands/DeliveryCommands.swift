import Foundation
import ParolaCore

extension ParolaAutomationServer {
    func deliveryCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "sendEntry",
                area: .library,
                summary: "Sends a library entry to one destination. Replies {outcome, …}: delivered carries the note path, queued the attempt and the next try, skipped the reason.",
                kind: .mutating,
                args: [
                    .init(name: "entryID", kind: .string(), required: true, summary: "Library entry id"),
                    .init(name: "destinationID", kind: .string(), required: true, summary: "Destination id from getState.destinations"),
                ],
                handler: { args, ctx in
                    let entryID = try args.string("entryID")
                    let raw = try args.string("destinationID")
                    guard let destinationID = UUID(uuidString: raw) else {
                        throw AutomationError.invalidArgs(field: "destinationID", reason: "must be a UUID")
                    }
                    guard let outcome = await ctx.model.sendEntry(entryID, to: destinationID) else {
                        throw AutomationError.precondition("Send To is disabled in this build")
                    }
                    return Self.encodeOutcome(outcome)
                }
            ),

            AutomationCommand(
                name: "listDeliveries",
                area: .library,
                summary: "The delivery receipts stored in an entry's manifest.",
                kind: .sync,
                args: [
                    .init(name: "entryID", kind: .string(), required: true, summary: "Library entry id"),
                ],
                handler: { args, ctx in
                    let entryID = try args.string("entryID")
                    let loaded = try await ctx.model.library.load(entryID)
                    return .object([
                        "receipts": .array(loaded.entry.deliveries.map { ParolaAutomationServer.encode($0) }),
                    ])
                }
            ),

            AutomationCommand(
                name: "setDestinations",
                area: .settings,
                summary: "Replaces the Send To list with an array of {kind, config} envelopes. In test mode a config may name a vaultPath instead of a vaultBookmark and the app makes the bookmark.",
                kind: .mutating,
                args: [
                    .init(name: "destinations", kind: .any, required: true, summary: "Array of destination envelopes"),
                ],
                handler: { args, ctx in
                    guard case .array(let raw)? = args.rawValue("destinations") else {
                        throw AutomationError.invalidArgs(field: "destinations", reason: "must be an array of destinations")
                    }
                    let json = try raw.map { try Self.resolvedEnvelope($0.jsonObject, testMode: ctx.model.mode == .test) }
                    guard let data = try? JSONSerialization.data(withJSONObject: json),
                          let decoded = try? JSONDecoder().decode([AnyDestination].self, from: data) else {
                        throw AutomationError.invalidArgs(field: "destinations", reason: "could not decode the given destinations")
                    }
                    ctx.model.setDestinations(decoded)
                    return .object(["destinations": ParolaAutomationServer.destinationsState(ctx.model)])
                }
            ),

            AutomationCommand(
                name: "installMockDestination",
                area: .test,
                summary: "Adds a destination that records what it is handed and writes nothing. Test-mode only.",
                kind: .mutating,
                args: [
                    .init(name: "name", kind: .string(), required: false, summary: "Row name"),
                    .init(name: "autoSend", kind: .boolean, required: false, summary: "Send as soon as a transcription finishes"),
                    .init(name: "categories", kind: .stringArray, required: false, summary: "transcription / meeting / dictation"),
                    .init(name: "failuresBeforeSuccess", kind: .integer, required: false, summary: "How many attempts fail first"),
                ],
                handler: { args, ctx in
                    guard ctx.model.mode == .test else {
                        throw AutomationError.precondition("only available in --test-mode")
                    }
                    let categories = try args.optionalStringArray("categories")
                        .map { Set($0.compactMap(EntryCategory.init(rawValue:))) }
                        ?? Set(EntryCategory.allCases)
                    let mock = MockDestination(
                        name: try args.optionalString("name") ?? "Mock destination",
                        autoSend: try args.optionalBool("autoSend") ?? false,
                        categories: categories
                    )
                    let failures = try args.optionalInt("failuresBeforeSuccess") ?? 0
                    await MockDeliveryRecorder.shared.setFailures(failures, for: mock.id)
                    ctx.model.setDestinations(ctx.model.destinations + [.mock(mock)])
                    return .object([
                        "installed": .bool(true),
                        "destinationID": .string(mock.id.uuidString),
                    ])
                }
            ),

            AutomationCommand(
                name: "setDestinationSecret",
                area: .test,
                summary: "Stores a destination secret under its reference, in the in-memory store. Test-mode only.",
                kind: .mutating,
                args: [
                    .init(name: "reference", kind: .string(), required: true, summary: "secretRef from the destination's config"),
                    .init(name: "value", kind: .string(), required: true, summary: "The secret"),
                ],
                handler: { args, ctx in
                    guard ctx.model.mode == .test else {
                        throw AutomationError.precondition("only available in --test-mode")
                    }
                    try await ctx.model.deliveryEnvironment.secrets.set(try args.string("value"), for: try args.string("reference"))
                    return .object(["stored": .bool(true)])
                }
            ),

            AutomationCommand(
                name: "openDestinationEditor",
                area: .test,
                summary: "Opens a Send To editor in the Send To pane, which has to be on screen. Test-mode only.",
                kind: .mutating,
                args: [
                    .init(name: "kind", kind: .string(), required: false, summary: "obsidianFolder / obsidianREST / webhook / notion: a blank editor for the kind"),
                    .init(name: "destinationID", kind: .string(), required: false, summary: "Edit this destination instead"),
                ],
                handler: { args, ctx in
                    guard ctx.model.mode == .test else {
                        throw AutomationError.precondition("only available in --test-mode")
                    }
                    if let raw = try args.optionalString("destinationID") {
                        guard let id = UUID(uuidString: raw) else {
                            throw AutomationError.invalidArgs(field: "destinationID", reason: "must be a UUID")
                        }
                        ctx.model.destinationEditorRequest = DestinationEditorRequest(target: .existing(id))
                    } else {
                        guard let kind = DestinationKind(rawValue: try args.optionalString("kind") ?? "") else {
                            throw AutomationError.invalidArgs(field: "kind", reason: "must be one of the destination kinds")
                        }
                        ctx.model.destinationEditorRequest = DestinationEditorRequest(target: .new(kind))
                    }
                    return .object(["requested": .bool(true)])
                }
            ),

            AutomationCommand(
                name: "readMockDeliveries",
                area: .test,
                summary: "What the mock destinations were handed, and the receipts they gave back. Test-mode only.",
                kind: .sync,
                handler: { _, ctx in
                    guard ctx.model.mode == .test else {
                        throw AutomationError.precondition("only available in --test-mode")
                    }
                    let payloads = await MockDeliveryRecorder.shared.recorded()
                    let receipts = await MockDeliveryRecorder.shared.receipts()
                    return .object([
                        "deliveries": .array(payloads.map { payload in
                            .object([
                                "entryID": .string(payload.entryID),
                                "title": .string(payload.title),
                                "category": .string(payload.category.rawValue),
                                "segmentCount": .int(payload.transcript.segments.count),
                                "markdownBytes": .int(payload.markdown.utf8.count),
                                "favorites": .array(payload.favorites.map { .int($0) }),
                            ])
                        }),
                        "receipts": .array(receipts.map { receipt in
                            .object([
                                "destinationName": .string(receipt.destinationName),
                                "destinationID": .string(receipt.destinationID.uuidString),
                            ])
                        }),
                    ])
                }
            ),
        ]
    }

    static func encodeOutcome(_ outcome: DeliveryOutcome) -> AutomationValue {
        switch outcome {
        case .delivered(let receipt):
            return .object([
                "outcome": .string("delivered"),
                "destinationName": .string(receipt.destinationName),
                "path": receipt.location.map { .string($0.path) } ?? .null,
            ])
        case .queued(let attempt, let nextAt):
            return .object([
                "outcome": .string("queued"),
                "attempt": .int(attempt),
                "nextAt": .string(Date.ISO8601FormatStyle().format(nextAt)),
            ])
        case .skipped(let reason):
            return .object([
                "outcome": .string("skipped"),
                "reason": .string(reason.message),
            ])
        }
    }

    static func destinationsState(_ model: AppModel) -> AutomationValue {
        .array(model.destinations.map { destination in
            .object([
                "id": .string(destination.id.uuidString),
                "kind": destination.kind.map { .string($0.rawValue) } ?? .null,
                "name": .string(destination.name),
                "isEnabled": .bool(destination.isEnabled),
                "autoSend": .bool(destination.autoSend),
                "categories": .array(destination.categories.map(\.rawValue).sorted().map { .string($0) }),
            ])
        })
    }

    /// Test mode lets a script name a folder instead of minting a bookmark for it; nothing else in
    /// the envelope is touched.
    private static func resolvedEnvelope(_ raw: Any, testMode: Bool) throws -> Any {
        guard testMode,
              var envelope = raw as? [String: Any],
              var config = envelope["config"] as? [String: Any],
              config["vaultBookmark"] == nil,
              let path = config["vaultPath"] as? String,
              !path.isEmpty
        else { return raw }
        let url = URL(fileURLWithPath: path)
        do {
            let bookmark = try ObsidianVaultFolderDestination.bookmark(for: url)
            config["vaultBookmark"] = bookmark.base64EncodedString()
        } catch {
            throw AutomationError.invalidArgs(field: "vaultPath", reason: "could not bookmark \(path): \(error.localizedDescription)")
        }
        envelope["config"] = config
        return envelope
    }
}
