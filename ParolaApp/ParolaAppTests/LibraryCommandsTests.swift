import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Bridge library commands", .serialized)
struct LibraryCommandsTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        temporaryDefaults()
    }

    private func makeRig() throws -> (AppModel, ParolaAutomationServer, AutomationContext, [String: AutomationCommand]) {
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("librarycommands"))
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let commands = Dictionary(uniqueKeysWithValues: server.libraryCommands().map { ($0.name, $0) })
        return (model, server, context, commands)
    }

    private func entry(id: String, title: String) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(originalAudioName: "\(title).m4a", modelName: "stub", language: "en")
        return LibraryEntry(id: id, bundleURL: URL(fileURLWithPath: "/tmp/LibraryCommandsTests/\(id).parola"), manifest: manifest)
    }

    private func arrayCount(_ value: AutomationValue) -> Int? {
        guard case .array(let items) = value else { return nil }
        return items.count
    }

    @Test("listEntries clamps a negative limit to empty instead of trapping")
    func listEntriesNegativeLimit() async throws {
        let (model, server, context, commands) = try makeRig()
        model.libraryEntries = [entry(id: "a", title: "Alpha"), entry(id: "b", title: "Beta")]
        let command = try #require(commands["listEntries"])
        let args = try command.validate(AutomationArgs(["limit": .int(-1)]))

        let result = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(arrayCount(result) == 0)
    }

    @Test("listEntries carries the duration and language the library holds")
    func listEntriesCarriesMetadata() async throws {
        let (model, server, context, commands) = try makeRig()
        let manifest = ParolaDocument.Manifest(
            originalAudioName: "talk.m4a",
            modelName: "stub",
            language: "it",
            durationSeconds: 650.0693
        )
        model.libraryEntries = [
            LibraryEntry(id: "a", bundleURL: URL(fileURLWithPath: "/tmp/a.parola"), manifest: manifest),
            entry(id: "b", title: "Beta"),
        ]
        let command = try #require(commands["listEntries"])

        let result = try await command.handler(try command.validate(AutomationArgs()), context)
        withExtendedLifetime(server) {}

        guard case .array(let items) = result, case .object(let first) = items[0],
              case .object(let second) = items[1] else {
            Issue.record("listEntries should return an array of objects")
            return
        }
        #expect(first["durationSeconds"] == .double(650.0693))
        #expect(first["language"] == .string("it"))
        #expect(first["modelName"] == .string("stub"))
        #expect(second["durationSeconds"] == .null, "an entry with no measured duration reports null")
        #expect(second["language"] == .string("en"))
        #expect(second["modelName"] == .string("stub"))
    }

    /// A scenario asserting on a row reads `displayTitle`; `title` stays the stored value.
    @Test("listEntries reports both the stored title and the shown one")
    func listEntriesCarriesTheDisplayTitle() async throws {
        let (model, server, context, commands) = try makeRig()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = ParolaDocument.Manifest(
            createdAt: created,
            originalAudioName: "audio.m4a",
            modelName: "stub",
            language: "en"
        )
        model.libraryEntries = [
            LibraryEntry(id: "a", bundleURL: URL(fileURLWithPath: "/tmp/a.parola"), manifest: manifest),
        ]
        let command = try #require(commands["listEntries"])

        let result = try await command.handler(try command.validate(AutomationArgs()), context)
        withExtendedLifetime(server) {}

        guard case .array(let items) = result, case .object(let first) = items[0] else {
            Issue.record("listEntries should return an array of objects")
            return
        }
        #expect(first["title"] == .string("audio"))
        #expect(first["displayTitle"] == .string(LibraryEntryDisplay.title(raw: "audio", createdAt: created)))
    }

    @Test("listEntries carries the AI title and summary, null when absent")
    func listEntriesCarriesCardMetadata() async throws {
        let (model, server, context, commands) = try makeRig()
        var withMetadata = ParolaDocument.Manifest(originalAudioName: "talk.m4a", modelName: "stub", language: "it")
        withMetadata.aiTitle = "Quarterly sync"
        withMetadata.shortSummary = "Budget review."
        model.libraryEntries = [
            LibraryEntry(id: "a", bundleURL: URL(fileURLWithPath: "/tmp/a.parola"), manifest: withMetadata),
            entry(id: "b", title: "Beta"),
        ]
        let command = try #require(commands["listEntries"])

        let result = try await command.handler(try command.validate(AutomationArgs()), context)
        withExtendedLifetime(server) {}

        guard case .array(let items) = result, case .object(let first) = items[0],
              case .object(let second) = items[1] else {
            Issue.record("listEntries should return an array of objects")
            return
        }
        #expect(first["aiTitle"] == .string("Quarterly sync"))
        #expect(first["shortSummary"] == .string("Budget review."))
        #expect(second["aiTitle"] == .null)
        #expect(second["shortSummary"] == .null)
    }

    private func makeCardMetadataEntry(_ model: AppModel) async throws -> LibraryEntry {
        try await model.library.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 9, text: String(repeating: "vendite per canale ", count: 6))],
                language: "it", modelName: "m"
            ),
            audioSource: nil, category: .transcription
        )
    }

    @Test("generateCardMetadata writes the AI title and summary using the mock model")
    func generateCardMetadataWritesFields() async throws {
        let (model, server, context, commands) = try makeRig()
        let entry = try await makeCardMetadataEntry(model)
        await MockLanguageModelStore.shared.install(
            provider: .foundation,
            response: MockLanguageModelResponse(text: "Piano vendite\nRiepilogo delle quote per canale.")
        )
        let command = try #require(commands["generateCardMetadata"])

        let result = try await command.handler(try command.validate(AutomationArgs(["id": .string(entry.id)])), context)
        withExtendedLifetime(server) {}

        guard case .object(let fields) = result else {
            Issue.record("generateCardMetadata should return an object")
            return
        }
        #expect(fields["generated"] == .bool(true))
        #expect(fields["aiTitle"] == .string("Piano vendite"))
        #expect(fields["shortSummary"] == .string("Riepilogo delle quote per canale."))
        await MockLanguageModelStore.shared.clear()
    }

    @Test("generateCardMetadata reports why it skipped when the AI feature is off")
    func generateCardMetadataReportsFeatureOff() async throws {
        let model = AppModel(
            skipBootstrap: true, defaults: makeIsolatedDefaults(),
            libraryURL: makeTempLibraryURL("librarycommands-nofeature"), features: []
        )
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let commands = Dictionary(uniqueKeysWithValues: server.libraryCommands().map { ($0.name, $0) })
        let entry = try await makeCardMetadataEntry(model)
        let command = try #require(commands["generateCardMetadata"])

        let result = try await command.handler(try command.validate(AutomationArgs(["id": .string(entry.id)])), context)
        withExtendedLifetime(server) {}

        guard case .object(let fields) = result else {
            Issue.record("generateCardMetadata should return an object")
            return
        }
        #expect(fields["generated"] == .bool(false))
        #expect(fields["reason"] != nil)
        #expect(fields["aiTitle"] == nil)
    }

    @Test("generateCardMetadata reports why it skipped when the toggle is off")
    func generateCardMetadataReportsToggleOff() async throws {
        let (model, server, context, commands) = try makeRig()
        model.generatesCardMetadata = false
        let entry = try await makeCardMetadataEntry(model)
        let command = try #require(commands["generateCardMetadata"])

        let result = try await command.handler(try command.validate(AutomationArgs(["id": .string(entry.id)])), context)
        withExtendedLifetime(server) {}

        guard case .object(let fields) = result else {
            Issue.record("generateCardMetadata should return an object")
            return
        }
        #expect(fields["generated"] == .bool(false))
        #expect(fields["reason"] != nil)
        #expect(fields["aiTitle"] == nil)
    }

    @Test("listDeletedEntries clamps a negative limit to empty instead of trapping")
    func listDeletedEntriesNegativeLimit() async throws {
        let (model, server, context, commands) = try makeRig()
        model.deletedEntries = [entry(id: "x", title: "Gone")]
        let command = try #require(commands["listDeletedEntries"])
        let args = try command.validate(AutomationArgs(["limit": .int(-1)]))

        let result = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(arrayCount(result) == 0)
    }

    @Test("setSegmentFavorite sets the state and reports it back")
    func setSegmentFavoriteSetsState() async throws {
        let (model, server, context, commands) = try makeRig()
        let entry = try await makeCardMetadataEntry(model)
        model.loadEntry(entry.id)
        for _ in 0..<200 where model.selectedEntryID != entry.id {
            try await Task.sleep(for: .milliseconds(10))
        }
        let command = try #require(commands["setSegmentFavorite"])

        let result = try await command.handler(
            try command.validate(AutomationArgs(["segmentID": .int(0), "isFavorite": .bool(true)])), context
        )
        withExtendedLifetime(server) {}

        guard case .object(let fields) = result else {
            Issue.record("setSegmentFavorite should return an object")
            return
        }
        #expect(fields["applied"] == .bool(true))
        #expect(fields["segmentID"] == .int(0))
        #expect(fields["isFavorite"] == .bool(true))
        #expect(model.isSegmentFavorite(0))
    }

    @Test("setSegmentFavorite awaits the write, so the state is correct with no sleep")
    func setSegmentFavoriteReportsActualStateWithoutSleep() async throws {
        let (model, server, context, commands) = try makeRig()
        let entry = try await makeCardMetadataEntry(model)
        model.loadEntry(entry.id)
        for _ in 0..<200 where model.selectedEntryID != entry.id {
            try await Task.sleep(for: .milliseconds(10))
        }
        let command = try #require(commands["setSegmentFavorite"])

        let result = try await command.handler(
            try command.validate(AutomationArgs(["segmentID": .int(0), "isFavorite": .bool(false)])), context
        )
        withExtendedLifetime(server) {}

        guard case .object(let fields) = result else {
            Issue.record("setSegmentFavorite should return an object")
            return
        }
        #expect(fields["isFavorite"] == .bool(false))
        #expect(!model.isSegmentFavorite(0))
    }

    @Test("setSegmentFavorite reports it was not applied when no entry is selected")
    func setSegmentFavoriteNoEntrySelected() async throws {
        let (model, server, context, commands) = try makeRig()
        model.selectedEntryID = nil
        let command = try #require(commands["setSegmentFavorite"])

        let result = try await command.handler(
            try command.validate(AutomationArgs(["segmentID": .int(0), "isFavorite": .bool(true)])), context
        )
        withExtendedLifetime(server) {}

        guard case .object(let fields) = result else {
            Issue.record("setSegmentFavorite should return an object")
            return
        }
        #expect(fields["applied"] == .bool(false))
    }
}
