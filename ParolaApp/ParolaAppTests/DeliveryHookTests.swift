import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Delivery completion hook")
struct DeliveryHookTests {

    private func makeModel(features: Set<ParolaFeature> = Set(ParolaFeature.allCases)) -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("deliveryhook"),
            features: features
        )
    }

    private static func transcript() -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "ciao mondo", speaker: "Ada")],
            language: "it",
            modelName: "stub",
            durationSeconds: 1
        )
    }

    @discardableResult
    private func installMock(
        on model: AppModel,
        recorder: MockDeliveryRecorder,
        autoSend: Bool = true,
        categories: Set<EntryCategory> = Set(EntryCategory.allCases)
    ) -> MockDestination {
        let mock = MockDestination(
            name: "Mock vault",
            autoSend: autoSend,
            categories: categories,
            recorder: recorder
        )
        model.setDestinations([.mock(mock)])
        return mock
    }

    private func poll(
        budget: Duration = .seconds(10),
        until condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    @Test("a finished transcription reaches the auto-send destinations")
    func autoSendsOnCompletion() async {
        let model = makeModel()
        let recorder = MockDeliveryRecorder()
        installMock(on: model, recorder: recorder)

        model.persistToLibrary(Self.transcript(), audioSource: nil, source: .file, title: "Riunione")

        #expect(await poll { await !recorder.recorded().isEmpty }, "the entry should have been sent")
        let entries = await model.library.list()
        #expect(await recorder.recorded().map(\.entryID) == entries.map(\.id))
        #expect(await recorder.recorded().first?.title == "Riunione")
    }

    @Test("the entry is in the library before it is sent, and the receipt lands on it")
    func sendsAfterThePersist() async throws {
        let model = makeModel()
        let recorder = MockDeliveryRecorder()
        installMock(on: model, recorder: recorder)

        model.persistToLibrary(Self.transcript(), audioSource: nil, source: .file, title: "Riunione")

        #expect(await poll { await !recorder.recorded().isEmpty })
        let entryID = try #require(await recorder.recorded().first?.entryID)
        let loaded = try await model.library.load(entryID)
        #expect(await poll { (try? await model.library.load(entryID).entry.deliveries.count) == 1 })
        #expect(loaded.entry.title == "Riunione")
    }

    @Test("a take saved without taking the selection is not sent")
    func inactivePersistNeverSends() async {
        let model = makeModel()
        let recorder = MockDeliveryRecorder()
        installMock(on: model, recorder: recorder)

        model.persistToLibrary(Self.transcript(), audioSource: nil, source: .file, activate: false)

        #expect(await poll { await model.library.list().count == 1 }, "the entry should still be saved")
        #expect(await recorder.recorded().isEmpty)
    }

    @Test("a batch run never auto-sends")
    func batchNeverSends() async {
        let model = makeModel()
        let recorder = MockDeliveryRecorder()
        installMock(on: model, recorder: recorder)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-delivery-batch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("clip.wav")
        try? Data("RIFFfakeaudio".utf8).write(to: source)
        let job = BatchJob(url: source)
        model.batchJobs = [job]

        await model.handleBatchEvent(.completed(jobID: job.id, transcript: Self.transcript()))

        #expect(await poll { await model.library.list().count == 1 }, "the batch entry should be saved")
        #expect(await recorder.recorded().isEmpty)
    }

    @Test("with the feature off nothing is sent")
    func featureOffNeverSends() async {
        let model = makeModel(features: Set(ParolaFeature.allCases).subtracting([.destinations]))
        let recorder = MockDeliveryRecorder()
        installMock(on: model, recorder: recorder)

        model.persistToLibrary(Self.transcript(), audioSource: nil, source: .file)

        #expect(await poll { await model.library.list().count == 1 })
        #expect(await recorder.recorded().isEmpty)
        #expect(model.deliveryNotice == nil)
    }

    @Test("a destination that does not take this category is left out")
    func categoryFilterAtTheHook() async {
        let model = makeModel()
        let recorder = MockDeliveryRecorder()
        installMock(on: model, recorder: recorder, categories: [.dictation])

        model.persistToLibrary(Self.transcript(), audioSource: nil, source: .file)

        #expect(await poll { await model.library.list().count == 1 })
        #expect(await recorder.recorded().isEmpty)
        #expect(model.deliveryNotice == nil)
    }

    @Test("a manual send reports itself in the toast")
    func manualSendSetsTheNotice() async throws {
        let model = makeModel()
        let recorder = MockDeliveryRecorder()
        let mock = installMock(on: model, recorder: recorder, autoSend: false)
        let seeded = try await model.library.add(
            transcript: Self.transcript(), audioSource: nil, category: .transcription, title: "Riunione"
        )

        let outcome = await model.sendEntry(seeded.id, to: mock.id)

        guard case .delivered = outcome else {
            Issue.record("expected a delivery, got \(String(describing: outcome))")
            return
        }
        #expect(model.deliveryNotice?.destinationName == "Mock vault")
        #expect(model.deliveryNotice?.entryID == seeded.id)
        if case .sent = model.deliveryNotice?.state {} else {
            Issue.record("expected a sent notice, got \(String(describing: model.deliveryNotice?.state))")
        }
        model.dismissDeliveryNotice()
        #expect(model.deliveryNotice == nil)
    }

    @Test("a failure queues the send and the toast offers a retry")
    func failedSendQueues() async throws {
        let model = makeModel()
        let recorder = MockDeliveryRecorder()
        let mock = installMock(on: model, recorder: recorder, autoSend: false)
        await recorder.setFailures(1, for: mock.id)
        let seeded = try await model.library.add(
            transcript: Self.transcript(), audioSource: nil, category: .transcription
        )

        let outcome = await model.sendEntry(seeded.id, to: mock.id)

        guard case .queued(let attempt, _) = outcome else {
            Issue.record("expected the send to be queued, got \(String(describing: outcome))")
            return
        }
        #expect(attempt == 1)
        if case .queued = model.deliveryNotice?.state {} else {
            Issue.record("expected a queued notice, got \(String(describing: model.deliveryNotice?.state))")
        }
        #expect(await model.deliveryEngine.pending().count == 1)
    }
}
