import Foundation
import os
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

private struct CallCount {
    var current = 0
    var peak = 0
    var total = 0
}

private final class CallTracker: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: CallCount())

    func enter() -> Int {
        state.withLock {
            $0.current += 1
            $0.total += 1
            $0.peak = max($0.peak, $0.current)
            return $0.total
        }
    }

    func leave() {
        state.withLock { $0.current -= 1 }
    }

    var peak: Int { state.withLock { $0.peak } }
    var total: Int { state.withLock { $0.total } }
}

@MainActor
@Suite("Card metadata queue")
struct CardMetadataQueueTests {
    private func makeModel() -> AppModel {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("card-queue")
        )
        model.cardRetryDelay = .zero
        return model
    }

    private func transcript(_ text: String) -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)],
            language: "en",
            modelName: "stub"
        )
    }

    private func addEntry(_ model: AppModel, _ text: String) async throws -> LibraryEntry {
        try await model.library.add(transcript: transcript(text), audioSource: nil, category: .transcription, source: .file)
    }

    @Test("cards run one at a time, each timed from when it starts rather than when it was queued")
    func cardsRunOneAtATime() async throws {
        let model = makeModel()
        let tracker = CallTracker()
        model.cardMetadataTimeout = .seconds(1)
        model.cardMetadataOperation = { transcript in
            _ = tracker.enter()
            try? await Task.sleep(for: .milliseconds(120))
            tracker.leave()
            return CardMetadata(title: "Card \(transcript.text)", summary: "Summary.")
        }
        var entries: [LibraryEntry] = []
        for index in 0..<12 {
            entries.append(try await addEntry(model, "take \(index)"))
        }

        for (index, entry) in entries.enumerated() {
            model.enqueueCardMetadata(for: entry.id, transcript: transcript("take \(index)"))
        }
        await model.awaitCardMetadataQueue()

        #expect(tracker.peak == 1)
        #expect(tracker.total == 12)
        for (index, entry) in entries.enumerated() {
            #expect(try await model.library.load(entry.id).entry.aiTitle == "Card take \(index)")
        }
    }

    @Test("a card that fails gets one more try once the queue drains")
    func failedCardIsRetried() async throws {
        let model = makeModel()
        let tracker = CallTracker()
        model.cardMetadataOperation = { _ in
            let call = tracker.enter()
            tracker.leave()
            return call == 1 ? nil : CardMetadata(title: "Second try", summary: "It worked.")
        }
        let entry = try await addEntry(model, "flaky")

        model.enqueueCardMetadata(for: entry.id, transcript: transcript("flaky"))
        await model.awaitCardMetadataQueue()

        #expect(tracker.total == 2)
        #expect(try await model.library.load(entry.id).entry.aiTitle == "Second try")
    }

    @Test("a card that fails twice is left alone after its one retry")
    func failedCardIsRetriedOnlyOnce() async throws {
        let model = makeModel()
        let tracker = CallTracker()
        model.cardMetadataOperation = { _ in
            _ = tracker.enter()
            tracker.leave()
            return nil
        }
        let entry = try await addEntry(model, "hopeless")

        model.enqueueCardMetadata(for: entry.id, transcript: transcript("hopeless"))
        await model.awaitCardMetadataQueue()

        #expect(tracker.total == 2)
        #expect(model.cardRetryIDs.isEmpty)
        #expect(try await model.library.load(entry.id).entry.aiTitle == nil)
    }

    @Test("cards still waiting when the toggle goes off don't run")
    func toggleOffStopsWaitingCards() async throws {
        let model = makeModel()
        let tracker = CallTracker()
        let (release, releaser) = AsyncStream<Void>.makeStream()
        model.cardMetadataOperation = { _ in
            _ = tracker.enter()
            for await _ in release { break }
            tracker.leave()
            return CardMetadata(title: "Ran", summary: "Ran.")
        }
        let first = try await addEntry(model, "first")
        let second = try await addEntry(model, "second")
        model.enqueueCardMetadata(for: first.id, transcript: transcript("first"))
        model.enqueueCardMetadata(for: second.id, transcript: transcript("second"))
        for _ in 0..<300 where tracker.total == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(tracker.total == 1)

        model.generatesCardMetadata = false
        releaser.finish()
        await model.awaitCardMetadataQueue()

        #expect(tracker.total == 1)
        #expect(model.cardRetryIDs.isEmpty)
        #expect(try await model.library.load(second.id).entry.aiTitle == nil)
    }

    @Test("a model this Mac can't run and a transcript too short to title are never retried")
    func permanentFailuresAreSkipped() {
        let unavailable = LanguageModelFactory.Failure.notAvailable("Apple Intelligence is off.")
        #expect(AppModel.cardOutcome(after: unavailable, modelOutOfReach: true).isSkipped)
        #expect(!AppModel.cardOutcome(after: unavailable, modelOutOfReach: false).isSkipped)
        #expect(AppModel.cardOutcome(after: CardMetadataService.Failure.tooShort, modelOutOfReach: false).isSkipped)
        #expect(!AppModel.cardOutcome(after: CancellationError(), modelOutOfReach: true).isSkipped)
    }

    @Test("auto-export doesn't wait for the card, and the landing still writes it")
    func autoExportRunsBeforeTheCard() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-card-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("memo.wav")
        try Data("fake".utf8).write(to: source)
        let model = makeModel()
        model.sweptFolders = { [] }
        model.autoExportRules = [AutoExportRule(sourceExtensions: ["wav"], presetIDs: [ExportPreset.builtIn(for: .txt)!.id])]
        let (release, releaser) = AsyncStream<Void>.makeStream()
        model.cardMetadataOperation = { _ in
            for await _ in release { break }
            return CardMetadata(title: "Held card", summary: "Released.")
        }

        let saved = try await model.land(RunLanding(kind: .file, transcript: transcript("export me"), audioSource: source)).value
        let sidecar = scratch.appendingPathComponent("memo.txt")
        var exported = false
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: sidecar.path) { exported = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(exported)
        #expect(try await model.library.load(saved.id).entry.aiTitle == nil)

        releaser.yield()
        releaser.finish()
        await model.awaitCardMetadataQueue()
        #expect(try await model.library.load(saved.id).entry.aiTitle == "Held card")
    }
}

private extension AppModel.CardMetadataOutcome {
    var isSkipped: Bool {
        if case .skipped = self { return true }
        return false
    }
}
