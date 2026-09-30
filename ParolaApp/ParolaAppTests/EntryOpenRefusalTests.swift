import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Opening an entry during a take")
struct EntryOpenRefusalTests {

    @MainActor
    private final class BeepCounter {
        var count = 0
    }

    private func makeModel(_ label: String) -> (AppModel, BeepCounter) {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL(label))
        let beeps = BeepCounter()
        model.refusalBeep = { beeps.count += 1 }
        return (model, beeps)
    }

    private func addEntry(to model: AppModel) async throws -> LibraryEntry {
        let entry = try await model.library.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "an older take")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil
        )
        await model.refreshLibraryAndWait()
        return entry
    }

    private func loadEntryCommand(_ model: AppModel) throws -> (AutomationCommand, AutomationContext, ParolaAutomationServer) {
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let commands = Dictionary(uniqueKeysWithValues: server.libraryCommands().map { ($0.name, $0) })
        return (try #require(commands["loadEntry"]), context, server)
    }

    @Test("a library row, a menu-bar item or a Statistics row opens the entry and the take keeps recording", .timeLimit(.minutes(1)))
    func libraryOpenDuringATake() async throws {
        let (model, beeps) = makeModel("take-row")
        let entry = try await addEntry(to: model)
        model.installTestTake(source: .microphone)

        #expect(model.openEntryFromLibrary(entry.id, inNewWindow: false))
        let opened = await waitUntil { model.selectedEntryID == entry.id && model.transcript?.text == "an older take" }

        #expect(opened)
        #expect(model.route == .transcript)
        #expect(model.recording?.isCapturing == true)
        #expect(beeps.count == 0)
    }

    @Test("a parola://open link opens the entry and the take keeps recording", .timeLimit(.minutes(1)))
    func urlOpenDuringATake() async throws {
        let (model, beeps) = makeModel("take-url")
        let entry = try await addEntry(to: model)
        model.installTestTake(source: .microphone)

        handleParolaOpen(try #require(URL(string: "parola://open?entry=\(entry.id)&t=5")), model: model)
        let opened = await waitUntil { model.selectedEntryID == entry.id }

        #expect(opened)
        #expect(model.recording?.isCapturing == true)
        #expect(beeps.count == 0)
    }

    @Test("the bridge's loadEntry opens the entry during a take", .timeLimit(.minutes(1)))
    func bridgeOpenDuringATake() async throws {
        let (model, beeps) = makeModel("take-bridge")
        let entry = try await addEntry(to: model)
        model.installTestTake(source: .microphone)
        let (command, context, server) = try loadEntryCommand(model)
        let args = try command.validate(AutomationArgs(["id": .string(entry.id)]))

        _ = try await command.handler(args, context)
        withExtendedLifetime(server) {}
        let opened = await waitUntil { model.selectedEntryID == entry.id }

        #expect(opened)
        #expect(model.recording?.isCapturing == true)
        #expect(beeps.count == 0)
    }

    @Test("a burn doesn't stop an entry from opening, and keeps going once it has", .timeLimit(.minutes(1)))
    func openingDuringABurn() async throws {
        let picker = TestFilePicker()
        let model = AppModel(
            skipBootstrap: true, defaults: temporaryDefaults(), filePicker: picker, libraryURL: makeTempLibraryURL("refuse-burn")
        )
        let entry = try await addEntry(to: model)
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "the burned one")], language: "en", modelName: "stub"
        )
        model.phase = .ready
        await picker.queueInputResponse([FileManager.default.temporaryDirectory.appendingPathComponent("in.mp4")])
        await picker.queueSaveResponse(FileManager.default.temporaryDirectory.appendingPathComponent("burn-open.mp4"))
        let burned = BurnedTranscripts()
        model.burnOperation = { transcript, _, _, _, progress in
            await burned.record(transcript.text)
            progress(0.25)
            try await Task.sleep(for: .milliseconds(300))
        }
        model.burnSubtitlesIntoVideo()
        await waitUntil { model.burnJob?.state == .running(progress: 0.25) }

        #expect(model.openEntryFromLibrary(entry.id, inNewWindow: false))
        await waitUntil { model.selectedEntryID == entry.id && model.transcript?.text == "an older take" }
        #expect(model.burnIsRunning)

        await waitUntil { model.burnJob?.state == .finished }
        #expect(model.burnJob?.state == .finished)
        #expect(await burned.texts == ["the burned one"])
    }

    @Test("with nothing recording, the row, the link and the bridge all open the entry", .timeLimit(.minutes(1)))
    func openingStillWorksWhenReady() async throws {
        let (model, beeps) = makeModel("refuse-ready")
        let entry = try await addEntry(to: model)
        model.phase = .ready

        #expect(model.openEntryFromLibrary(entry.id, inNewWindow: false))
        await waitUntil { model.selectedEntryID == entry.id && model.transcript?.text == "an older take" }

        model.clearLoadedEntry()
        handleParolaOpen(try #require(URL(string: "parola://open?entry=\(entry.id)")), model: model)
        await waitUntil { model.selectedEntryID == entry.id }

        model.clearLoadedEntry()
        let (command, context, server) = try loadEntryCommand(model)
        _ = try await command.handler(try command.validate(AutomationArgs(["id": .string(entry.id)])), context)
        withExtendedLifetime(server) {}
        await waitUntil { model.selectedEntryID == entry.id }
        #expect(beeps.count == 0)
    }
}

private actor BurnedTranscripts {
    private(set) var texts: [String] = []

    func record(_ text: String) {
        texts.append(text)
    }
}
