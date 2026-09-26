import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Deliveries follow the entry")
struct DeliveryEntryTests {

    private func makeModel(_ label: String) -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL(label),
            features: Set(ParolaFeature.allCases)
        )
    }

    private func installMock(on model: AppModel, recorder: MockDeliveryRecorder, failures: Int = 0) async -> MockDestination {
        let mock = MockDestination(name: "Mock vault", autoSend: false, recorder: recorder)
        await recorder.setFailures(failures, for: mock.id)
        model.setDestinations([.mock(mock)])
        return mock
    }

    private func addEntry(to model: AppModel, text: String) async throws -> LibraryEntry {
        try await model.library.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil
        )
    }

    @Test("a send right after an edit carries the edit", .timeLimit(.minutes(1)))
    func sendCarriesTheLastEdit() async throws {
        let model = makeModel("delivery-edit")
        let recorder = MockDeliveryRecorder()
        let mock = await installMock(on: model, recorder: recorder)
        let entry = try await addEntry(to: model, text: "the first draft")
        try await model.openEntry(entry.id)

        model.editSegment(id: 0, newText: "the corrected line")
        let outcome = await model.sendEntry(entry.id, to: mock.id)

        #expect(outcome?.isDelivered == true)
        #expect(await recorder.recorded().first?.transcript.text == "the corrected line")
    }

    @Test("deleting an entry drops the delivery waiting to retry it", .timeLimit(.minutes(1)))
    func deleteDropsTheQueuedDelivery() async throws {
        let model = makeModel("delivery-delete")
        let recorder = MockDeliveryRecorder()
        let mock = await installMock(on: model, recorder: recorder, failures: 1)
        let entry = try await addEntry(to: model, text: "the vault was offline")
        let outcome = await model.sendEntry(entry.id, to: mock.id)
        guard case .queued = outcome else {
            Issue.record("expected the failed send to queue, got \(String(describing: outcome))")
            return
        }

        model.deleteEntry(entry.id)

        await waitUntil { await model.deliveryEngine.pending().isEmpty }
        #expect(await model.deliveryEngine.recentLog().last?.event == .dropped)
        #expect(await recorder.recorded().isEmpty)
    }
}
