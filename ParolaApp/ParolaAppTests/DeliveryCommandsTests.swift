import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Bridge delivery commands", .serialized)
struct DeliveryCommandsTests {

    private func makeRig(
        mode: AppBootstrap.Mode = .test
    ) throws -> (AppModel, ParolaAutomationServer, AutomationContext, [String: AutomationCommand]) {
        let bootstrap = AppBootstrap(
            mode: mode,
            library: makeTempLibraryURL("deliverycommands"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: SystemFilePicker(),
            enabledFeaturesOverride: Set(ParolaFeature.allCases)
        )
        let model = AppModel(bootstrap: bootstrap)
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let commands = Dictionary(uniqueKeysWithValues: server.deliveryCommands().map { ($0.name, $0) })
        return (model, server, context, commands)
    }

    private func field(_ value: AutomationValue, _ key: String) throws -> AutomationValue {
        guard case .object(let fields) = value, let found = fields[key] else {
            throw AutomationError.notFound(kind: "field", id: key)
        }
        return found
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

    private func seed(_ model: AppModel, title: String = "Riunione") async throws -> LibraryEntry.ID {
        let entry = try await model.library.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "ciao", speaker: "Ada")],
                language: "it",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription,
            title: title
        )
        return entry.id
    }

    @Test("installMockDestination lands in the list and in getState")
    func installMock() async throws {
        // Cleared here rather than in a defer: a `Task` in a defer is unordered and can land
        // after the next test has installed its own failures.
        await MockDeliveryRecorder.shared.reset()
        let (model, server, context, commands) = try makeRig()

        let installed = try await run(commands, "installMockDestination", ["name": .string("Bridge mock")], context)

        #expect(try field(installed, "installed") == .bool(true))
        #expect(model.destinations.count == 1)
        guard case .array(let rows) = ParolaAutomationServer.destinationsState(model) else {
            Issue.record("expected a destination array")
            return
        }
        #expect(try field(rows[0], "name") == .string("Bridge mock"))
        #expect(try field(rows[0], "kind") == .string("obsidianFolder"))
        withExtendedLifetime(server) {}
    }

    @Test("sendEntry delivers, records the receipt and reads it back")
    func sendEntryRoundTrip() async throws {
        // Cleared here rather than in a defer: a `Task` in a defer is unordered and can land
        // after the next test has installed its own failures.
        await MockDeliveryRecorder.shared.reset()
        let (model, server, context, commands) = try makeRig()
        let entryID = try await seed(model)
        let installed = try await run(commands, "installMockDestination", [:], context)
        let destinationID = try field(installed, "destinationID")
        guard case .string(let destinationRaw) = destinationID else { return }

        let sent = try await run(
            commands, "sendEntry",
            ["entryID": .string(entryID), "destinationID": .string(destinationRaw)],
            context
        )
        #expect(try field(sent, "outcome") == .string("delivered"))

        let recorded = try await run(commands, "readMockDeliveries", [:], context)
        guard case .array(let deliveries) = try field(recorded, "deliveries") else {
            Issue.record("expected recorded deliveries")
            return
        }
        #expect(deliveries.count == 1)
        #expect(try field(deliveries[0], "entryID") == .string(entryID))
        #expect(try field(deliveries[0], "title") == .string("Riunione"))

        let listed = try await run(commands, "listDeliveries", ["entryID": .string(entryID)], context)
        guard case .array(let receipts) = try field(listed, "receipts") else {
            Issue.record("expected receipts")
            return
        }
        #expect(receipts.count == 1)
        #expect(try field(receipts[0], "destinationName") == .string("Mock destination"))
        withExtendedLifetime(server) {}
    }

    @Test("a mock told to fail reports the send as queued")
    func failingSendIsQueued() async throws {
        // Cleared here rather than in a defer: a `Task` in a defer is unordered and can land
        // after the next test has installed its own failures.
        await MockDeliveryRecorder.shared.reset()
        let (model, server, context, commands) = try makeRig()
        let entryID = try await seed(model)
        let installed = try await run(
            commands, "installMockDestination", ["failuresBeforeSuccess": .int(1)], context
        )
        guard case .string(let destinationRaw) = try field(installed, "destinationID") else { return }

        let sent = try await run(
            commands, "sendEntry",
            ["entryID": .string(entryID), "destinationID": .string(destinationRaw)],
            context
        )

        #expect(try field(sent, "outcome") == .string("queued"))
        #expect(try field(sent, "attempt") == .int(1))
        withExtendedLifetime(server) {}
    }

    @Test("setDestinations turns a test-mode vaultPath into a bookmark")
    func setDestinationsBookmarksAPath() async throws {
        let (model, server, context, commands) = try makeRig()
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-bridge-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        _ = try await run(
            commands, "setDestinations",
            ["destinations": .array([
                .object([
                    "kind": .string("obsidianFolder"),
                    "config": .object([
                        "id": .string("6C9C1E1E-0000-0000-0000-0000000000BB"),
                        "name": .string("Throwaway vault"),
                        "vaultPath": .string(vault.path),
                        "subfolder": .string("Transcripts"),
                    ]),
                ]),
            ])],
            context
        )

        guard case .obsidianFolder(let destination)? = model.destinations.first else {
            Issue.record("expected an Obsidian destination, got \(model.destinations)")
            return
        }
        #expect(!destination.vaultBookmark.isEmpty)
        #expect(destination.vaultPath == vault.path)
        #expect(destination.subfolder == "Transcripts")
        withExtendedLifetime(server) {}
    }

    @Test("outside test mode a vaultPath is left alone")
    func vaultPathIsTestModeOnly() async throws {
        let (model, server, context, commands) = try makeRig(mode: .normal)

        _ = try await run(
            commands, "setDestinations",
            ["destinations": .array([
                .object([
                    "kind": .string("obsidianFolder"),
                    "config": .object([
                        "id": .string("6C9C1E1E-0000-0000-0000-0000000000CC"),
                        "name": .string("Vault"),
                        "vaultPath": .string("/tmp/parola-not-test-mode"),
                    ]),
                ]),
            ])],
            context
        )

        guard case .obsidianFolder(let destination)? = model.destinations.first else {
            Issue.record("expected an Obsidian destination, got \(model.destinations)")
            return
        }
        #expect(destination.vaultBookmark.isEmpty)
        withExtendedLifetime(server) {}
    }

    @Test("the test-mode commands refuse to run outside test mode")
    func testModeOnly() async throws {
        let (_, server, context, commands) = try makeRig(mode: .normal)
        await #expect(throws: AutomationError.self) {
            _ = try await run(commands, "installMockDestination", [:], context)
        }
        await #expect(throws: AutomationError.self) {
            _ = try await run(commands, "readMockDeliveries", [:], context)
        }
        withExtendedLifetime(server) {}
    }

    @Test("every delivery command is in the catalog")
    func commandsAreRegistered() throws {
        let (_, server, _, _) = try makeRig()
        let names = Set(server.commandNames())
        for name in ["sendEntry", "listDeliveries", "setDestinations", "installMockDestination", "readMockDeliveries"] {
            #expect(names.contains(name), "\(name) is missing from the catalog")
        }
    }
}
