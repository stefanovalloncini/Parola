import Foundation
import os
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Bridge translation commands", .serialized)
struct TranslationCommandsTests {

    private func makeRig() throws -> (AppModel, ParolaAutomationServer, AutomationContext, [String: AutomationCommand]) {
        let bootstrap = AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("translationcommands"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: SystemFilePicker(),
            enabledFeaturesOverride: Set(ParolaFeature.allCases)
        )
        let model = AppModel(bootstrap: bootstrap)
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let commands = Dictionary(uniqueKeysWithValues: server.transcriptCommands().map { ($0.name, $0) })
        return (model, server, context, commands)
    }

    private func loaded(_ model: AppModel) async throws -> LibraryEntry.ID {
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let seeded = try await seedStore.add(
            transcript: Transcript(
                segments: [
                    TranscriptSegment(id: 0, start: 0, end: 1, text: "ciao mondo"),
                    TranscriptSegment(id: 1, start: 1, end: 2, text: "come stai"),
                ],
                language: "it",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        model.loadEntry(seeded.id)
        for _ in 0..<200 where model.selectedEntryID != seeded.id {
            try await Task.sleep(for: .milliseconds(10))
        }
        return seeded.id
    }

    private func field(_ value: AutomationValue, _ key: String) throws -> AutomationValue {
        guard case .object(let fields) = value, let found = fields[key] else {
            throw AutomationError.notFound(kind: "field", id: key)
        }
        return found
    }

    @Test("translateTranscript reports what it stored")
    func translateReportsTheTranslation() async throws {
        let (model, server, context, commands) = try makeRig()
        _ = try await loaded(model)
        model.translationCoordinator.translatorOverride = MockTranslator(mode: .reverseWords)
        let command = try #require(commands["translateTranscript"])
        let args = try command.validate(AutomationArgs(["language": .string("en")]))

        let result = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(try field(result, "translated") == .bool(true))
        #expect(try field(result, "targetLanguage") == .string("en"))
        #expect(try field(result, "segmentCount") == .int(2))
        #expect(try field(result, "provider") == .string("mock"))
    }

    @Test("a translation that produced nothing says why")
    func refusalCarriesAReason() async throws {
        let (model, server, context, commands) = try makeRig()
        _ = try await loaded(model)
        model.translationCoordinator.translatorOverride = MockTranslator(mode: .map, map: [:])
        let command = try #require(commands["translateTranscript"])
        let args = try command.validate(AutomationArgs(["language": .string("en")]))

        let result = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(try field(result, "translated") == .bool(false))
        #expect(try field(result, "reason") == .string("the transcript has no text to translate"))
    }

    @Test("a failed run hands its own message back")
    func failureCarriesTheMessage() async throws {
        let (model, server, context, commands) = try makeRig()
        _ = try await loaded(model)
        model.translationCoordinator.translatorOverride = FailingTranslator()
        let command = try #require(commands["translateTranscript"])
        let args = try command.validate(AutomationArgs(["language": .string("en")]))

        let result = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(try field(result, "translated") == .bool(false))
        #expect(try field(result, "reason") != .string(""))
    }

    @Test("translateTranscript needs a transcript")
    func refusesWithoutATranscript() async throws {
        let (_, server, context, commands) = try makeRig()
        let command = try #require(commands["translateTranscript"])
        let args = try command.validate(AutomationArgs(["language": .string("en")]))

        await #expect(throws: AutomationError.self) {
            _ = try await command.handler(args, context)
        }
        withExtendedLifetime(server) {}
    }

    @Test("removeTranslation says whether there was one")
    func removeReportsWhatItFound() async throws {
        let (model, server, context, commands) = try makeRig()
        _ = try await loaded(model)
        let command = try #require(commands["removeTranslation"])
        let args = try command.validate(AutomationArgs([:]))

        #expect(try await command.handler(args, context) == .object(["removed": .bool(false)]))

        model.translationCoordinator.translatorOverride = MockTranslator(mode: .reverseWords)
        await model.translateTranscript(to: "en")

        #expect(try await command.handler(args, context) == .object(["removed": .bool(true)]))
        withExtendedLifetime(server) {}
    }

    @Test("getState carries a first run while it is still going")
    func stateReportsARunInFlight() async throws {
        let (model, server, _, _) = try makeRig()
        _ = try await loaded(model)
        let seen = OSAllocatedUnfairLock<[AutomationValue]>(initialState: [])
        model.translationCoordinator.translatorOverride = InspectingTranslator {
            let snapshot = await MainActor.run { ParolaAutomationServer.translationState(model) }
            seen.withLock { $0.append(snapshot) }
        }

        await model.translateTranscript(to: "en")

        let midRun = try #require(seen.withLock { $0 }.first)
        #expect(try field(midRun, "inProgress") == .bool(true))
        #expect(try field(midRun, "targetLanguage") == .string("en"))
        #expect(try field(midRun, "provider") == .string("stub"))

        let settled = ParolaAutomationServer.translationState(model)
        #expect(try field(settled, "inProgress") == .bool(false))
        #expect(try field(settled, "segmentCount") == .int(2))
        withExtendedLifetime(server) {}
    }

    @Test("getState carries no translation when there is none")
    func stateIsNullWithoutATranslation() async throws {
        let (model, server, _, _) = try makeRig()
        _ = try await loaded(model)

        #expect(ParolaAutomationServer.translationState(model) == .null)
        withExtendedLifetime(server) {}
    }
}

private struct FailingTranslator: TranscriptTranslating {
    let providerName = "stub"

    func translate(
        _ texts: [(id: Int, text: String)], from source: String?, to target: String
    ) async throws -> [Int: String] {
        throw ParolaError.ioError("translator went down")
    }
}

private struct InspectingTranslator: TranscriptTranslating {
    let providerName = "stub"
    let midRun: @Sendable () async -> Void

    func translate(
        _ texts: [(id: Int, text: String)], from source: String?, to target: String
    ) async throws -> [Int: String] {
        await midRun()
        return Dictionary(uniqueKeysWithValues: texts.map { ($0.id, "T\($0.id)") })
    }
}
