import AppKit
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

    @Test("a finished transcription reaches the auto-send destinations")
    func autoSendsOnCompletion() async {
        let model = makeModel()
        let recorder = MockDeliveryRecorder()
        installMock(on: model, recorder: recorder)

        model.land(RunLanding(kind: .file, transcript: Self.transcript(), title: "Riunione"))

        let recorderWait = await waitUntil(timeoutMs: 10_000) { await !recorder.recorded().isEmpty }
        #expect(recorderWait, "the entry should have been sent")
        let entries = await model.library.list()
        #expect(await recorder.recorded().map(\.entryID) == entries.map(\.id))
        #expect(await recorder.recorded().first?.title == "Riunione")
    }

    @Test("the entry is in the library before it is sent, and the receipt lands on it")
    func sendsAfterThePersist() async throws {
        let model = makeModel()
        let recorder = MockDeliveryRecorder()
        installMock(on: model, recorder: recorder)

        model.land(RunLanding(kind: .file, transcript: Self.transcript(), title: "Riunione"))

        let recorderWait = await waitUntil(timeoutMs: 10_000) { await !recorder.recorded().isEmpty }
        #expect(recorderWait)
        let entryID = try #require(await recorder.recorded().first?.entryID)
        let loaded = try await model.library.load(entryID)
        let libraryWait = await waitUntil(timeoutMs: 10_000) { (try? await model.library.load(entryID).entry.deliveries.count) == 1 }
        #expect(libraryWait)
        #expect(loaded.entry.title == "Riunione")
    }

    @Test("a take saved without taking the selection is not sent")
    func inactivePersistNeverSends() async {
        let model = makeModel()
        let recorder = MockDeliveryRecorder()
        installMock(on: model, recorder: recorder)

        model.land(RunLanding(kind: .salvagedTake, transcript: Self.transcript()))

        let libraryWait = await waitUntil(timeoutMs: 10_000) { await model.library.list().count == 1 }
        #expect(libraryWait, "the entry should still be saved")
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

        let libraryWait = await waitUntil(timeoutMs: 10_000) { await model.library.list().count == 1 }
        #expect(libraryWait, "the batch entry should be saved")
        #expect(await recorder.recorded().isEmpty)
    }

    @Test("with the feature off nothing is sent")
    func featureOffNeverSends() async {
        let model = makeModel(features: Set(ParolaFeature.allCases).subtracting([.destinations]))
        let recorder = MockDeliveryRecorder()
        installMock(on: model, recorder: recorder)

        model.land(RunLanding(kind: .file, transcript: Self.transcript()))

        let libraryWait = await waitUntil(timeoutMs: 10_000) { await model.library.list().count == 1 }
        #expect(libraryWait)
        #expect(await recorder.recorded().isEmpty)
        #expect(model.deliveryNotice == nil)
    }

    @Test("a destination that does not take this category is left out")
    func categoryFilterAtTheHook() async {
        let model = makeModel()
        let recorder = MockDeliveryRecorder()
        installMock(on: model, recorder: recorder, categories: [.dictation])

        model.land(RunLanding(kind: .file, transcript: Self.transcript()))

        let libraryWait = await waitUntil(timeoutMs: 10_000) { await model.library.list().count == 1 }
        #expect(libraryWait)
        #expect(await recorder.recorded().isEmpty)
        #expect(model.deliveryNotice == nil)
    }

    @Test("a delivery queued by an earlier launch runs at the next launch")
    func queuedDeliveryResumesAtLaunch() async throws {
        let defaults = temporaryDefaults()
        let libraryURL = makeTempLibraryURL("deliveryresume")
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-resume-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let seeded = try await LibraryStore(libraryURL: libraryURL, extraIndexer: nil).add(
            transcript: Self.transcript(), audioSource: nil, category: .transcription, title: "Riunione"
        )
        let destination = ObsidianVaultFolderDestination(
            name: "Vault",
            vaultBookmark: try ObsidianVaultFolderDestination.bookmark(for: vault),
            vaultPath: vault.path
        )
        defaults.set(
            try JSONEncoder().encode([AnyDestination.obsidianFolder(destination)]),
            forKey: "destinations"
        )
        let store = DeliveryQueueStore(
            directory: libraryURL.appendingPathComponent("Delivery", isDirectory: true)
        )
        store.save(queue: [
            QueuedDelivery(
                entryID: seeded.id,
                destinationID: destination.id,
                attempt: 1,
                nextAttemptAt: Date(timeIntervalSince1970: 0)
            )
        ])

        let written = try #require(defaults.data(forKey: "destinations"))
        #expect(try JSONDecoder().decode([AnyDestination].self, from: written).count == 1)

        // No send of any kind: building the model is the whole trigger.
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: libraryURL)

        let note = vault.appendingPathComponent("Riunione.md")
        let fileExistsWait = await waitUntil(timeoutMs: 10_000) { FileManager.default.fileExists(atPath: note.path) }
        #expect(
            fileExistsWait,
            "the queued delivery should have run at launch"
        )
        let loadQueueWait = await waitUntil(timeoutMs: 10_000) { store.loadQueue().isEmpty }
        #expect(loadQueueWait)
        #expect(model.destinations.count == 1)
    }

    @Test("the toast belongs to the entry it was raised for")
    func noticeIsKeyedToItsEntry() {
        let model = makeModel()
        model.deliveryNotice = DeliveryNotice(
            entryID: "entry-A",
            destinationID: UUID(),
            destinationName: "Vault",
            state: .sent(nil)
        )

        model.selectedEntryID = "entry-B"
        #expect(model.visibleDeliveryNotice == nil, "another entry's send must not show here")

        model.selectedEntryID = "entry-A"
        #expect(model.visibleDeliveryNotice != nil)

        model.selectedEntryID = nil
        #expect(model.visibleDeliveryNotice != nil, "a library-row send stays visible with nothing open")
    }

    @Test("a fan-out reports every destination, and a failure wins")
    func fanOutNotice() throws {
        let first = UUID()
        let second = UUID()
        let delivered = DeliveryAttempt(
            destinationID: first,
            destinationName: "Vault A",
            outcome: .delivered(
                DeliveryReceipt(
                    destinationID: first,
                    destinationName: "Vault A",
                    deliveredAt: Date(),
                    location: URL(fileURLWithPath: "/tmp/parola-fanout/A.md")
                )
            )
        )
        let alsoDelivered = DeliveryAttempt(
            destinationID: second,
            destinationName: "Vault B",
            outcome: .delivered(
                DeliveryReceipt(
                    destinationID: second,
                    destinationName: "Vault B",
                    deliveredAt: Date(),
                    location: URL(fileURLWithPath: "/tmp/parola-fanout/B.md")
                )
            )
        )
        let queued = DeliveryAttempt(
            destinationID: second,
            destinationName: "Vault B",
            outcome: .queued(attempt: 1, nextAt: Date().addingTimeInterval(60))
        )

        let one = try #require(AppModel.notice(for: [delivered], entryID: "entry-1"))
        #expect(one.destinationName == "Vault A")
        #expect(one.state == .sent(URL(fileURLWithPath: "/tmp/parola-fanout/A.md")))

        let both = try #require(AppModel.notice(for: [delivered, alsoDelivered], entryID: "entry-1"))
        #expect(both.destinationName == "Vault A, Vault B")
        #expect(both.state == .sent(nil), "Reveal can only point at one note")

        let mixed = try #require(AppModel.notice(for: [delivered, queued], entryID: "entry-1"))
        #expect(mixed.destinationName == "Vault B")
        #expect(mixed.destinationID == second)
        if case .queued = mixed.state {} else {
            Issue.record("expected the queued destination to win, got \(mixed.state)")
        }
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

    @Test("fixing a destination in Settings sends what queued for it at once")
    func updatingADestinationRetriesItsQueue() async throws {
        let model = makeModel()
        let recorder = MockDeliveryRecorder()
        let mock = installMock(on: model, recorder: recorder, autoSend: false)
        await recorder.setReachable(false, for: mock.id)
        let seeded = try await model.library.add(
            transcript: Self.transcript(), audioSource: nil, category: .transcription
        )
        _ = await model.sendEntry(seeded.id, to: mock.id)
        #expect(await model.deliveryEngine.pending().count == 1)

        await recorder.setReachable(true, for: mock.id)
        var fixed = mock
        fixed.name = "Mock vault, found"
        model.updateDestination(.mock(fixed))

        let deliveryEngineWait = await waitUntil(timeoutMs: 10_000) { await model.deliveryEngine.pending().isEmpty }
        #expect(deliveryEngineWait)
        #expect(await recorder.recorded().map(\.entryID) == [seeded.id])
    }

    @Test("a volume mounting sends what queued for a destination that is back")
    func aMountRetriesTheQueue() async throws {
        let model = AppModel(bootstrap: AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("deliveryhook-mount"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: TestFilePicker(),
            clock: ContinuousClock()
        ))
        let recorder = MockDeliveryRecorder()
        let mock = installMock(on: model, recorder: recorder, autoSend: false)
        await recorder.setReachable(false, for: mock.id)
        let seeded = try await model.library.add(
            transcript: Self.transcript(), audioSource: nil, category: .transcription
        )
        _ = await model.sendEntry(seeded.id, to: mock.id)
        #expect(model.volumeMountObservation != nil, "the launch listens for mounts")
        // A private center: a mount posted on the workspace's would reach the test host's own model too.
        let center = NotificationCenter()
        model.observeVolumeMounts(on: center)

        center.post(name: NSWorkspace.didMountNotification, object: nil)
        await settle()
        #expect(await model.deliveryEngine.pending().count == 1, "still unreachable: nothing moves")

        await recorder.setReachable(true, for: mock.id)
        center.post(name: NSWorkspace.didMountNotification, object: nil)

        let deliveryEngineWait = await waitUntil(timeoutMs: 10_000) { await model.deliveryEngine.pending().isEmpty }
        #expect(deliveryEngineWait)
        #expect(await recorder.recorded().map(\.entryID) == [seeded.id])
    }
}
