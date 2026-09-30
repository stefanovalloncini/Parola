import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("AppModel selection safety")
struct AppModelSelectionSafetyTests {
    private func makeModel() -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("selection-safety")
        )
    }

    private func makeTranscript(_ text: String = "hi") -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)],
            language: "en",
            modelName: "stub"
        )
    }

    private func poll(
        budget: Duration = .seconds(5),
        until condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    @Test("a landing takes the selection when the user stayed put")
    func persistSelectsNewEntryWithoutNavigation() async {
        let model = makeModel()
        let result = makeTranscript()
        model.transcript = result
        model.land(RunLanding(kind: .file, transcript: result))
        let selected = await poll { model.selectedEntryID != nil }
        #expect(selected, "the freshly saved recording should become the selected entry")
    }

    @Test("a navigation during a landing keeps the user's selection")
    func persistDoesNotStealSelectionAfterNavigation() async {
        let model = makeModel()
        let result = makeTranscript()
        model.transcript = result
        model.land(RunLanding(kind: .file, transcript: result))
        // The user opens another entry while library.add is still copying.
        model.loadEntryGeneration &+= 1

        let saved = await poll { await model.library.list().count == 1 }
        #expect(saved, "the entry should still be added to the library")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(
            model.selectedEntryID == nil,
            "the late selection assignment must not repoint edits at the new entry"
        )
    }

    @Test("opening a project document clears the library selection")
    func openProjectClearsSelection() async throws {
        let model = makeModel()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundleBase = dir.appendingPathComponent("take")
        _ = try ParolaDocument.write(transcript: makeTranscript("project text"), audioURL: nil, to: bundleBase)

        model.selectedEntryID = "stale-entry"
        await model.openProjectDocument(at: bundleBase.appendingPathExtension("parola"))

        #expect(model.transcript?.segments.first?.text == "project text")
        #expect(
            model.selectedEntryID == nil,
            "editing the opened project would overwrite the still-selected library entry"
        )
    }

    @Test("batch events paint the batch's phase and leave a take recording on its Stage")
    func batchEventsLeaveTheTake() async {
        let model = makeModel()
        let job = BatchJob(url: URL(fileURLWithPath: "/tmp/selection-safety.wav"))
        model.batchJobs = [job]
        model.installTestTake(source: .microphone)

        await model.handleBatchEvent(.started(jobID: job.id))
        #expect(model.phase == .transcribing(file: job.url))
        #expect(model.recording?.isCapturing == true)
        #expect(model.route == .recording, "a batch job starting must not hide the take's Stage")

        await model.handleBatchEvent(.finished)
        #expect(model.phase == .ready)
        #expect(model.recording?.isCapturing == true)
        #expect(model.route == .recording)
    }
}
