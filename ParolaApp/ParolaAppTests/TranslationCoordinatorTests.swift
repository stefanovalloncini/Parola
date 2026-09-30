import Foundation
import os
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

private final class CallCounter: Sendable {
    private let state = OSAllocatedUnfairLock<Int>(initialState: 0)
    func next() -> Int { state.withLock { value in defer { value += 1 }; return value } }
    var count: Int { state.withLock { $0 } }
}

/// Translates every batch until `failAfter` batches have gone through, then throws.
private struct FlakyTranslator: TranscriptTranslating {
    let providerName = "stub"
    let failAfter: Int
    let counter = CallCounter()

    func translate(
        _ texts: [(id: Int, text: String)], from source: String?, to target: String
    ) async throws -> [Int: String] {
        guard counter.next() < failAfter else { throw ParolaError.ioError("translator went down") }
        return Dictionary(uniqueKeysWithValues: texts.map { ($0.id, "T\($0.id)") })
    }
}

/// Holds a run open until the test lets it go.
private actor TranslationGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// Waits on a gate before handing its batch back, so a test can hold a run in flight.
private struct GatedTranslator: TranscriptTranslating {
    let providerName = "stub"
    let gate: TranslationGate

    func translate(
        _ texts: [(id: Int, text: String)], from source: String?, to target: String
    ) async throws -> [Int: String] {
        await gate.wait()
        return Dictionary(uniqueKeysWithValues: texts.map { ($0.id, "T\($0.id)") })
    }
}

/// Translates a batch, then runs `afterBatch` — the test uses it to cancel mid-run.
private struct InterruptingTranslator: TranscriptTranslating {
    let providerName = "stub"
    let afterBatch: @Sendable () async -> Void

    func translate(
        _ texts: [(id: Int, text: String)], from source: String?, to target: String
    ) async throws -> [Int: String] {
        let out = Dictionary(uniqueKeysWithValues: texts.map { ($0.id, "T\($0.id)") })
        await afterBatch()
        return out
    }
}

/// Runs `beforeReturning` before handing its batch back — the test uses it to leave the entry.
private struct LeavingTranslator: TranscriptTranslating {
    let providerName = "stub"
    let beforeReturning: @Sendable () async -> Void

    func translate(
        _ texts: [(id: Int, text: String)], from source: String?, to target: String
    ) async throws -> [Int: String] {
        await beforeReturning()
        return Dictionary(uniqueKeysWithValues: texts.map { ($0.id, "T\($0.id)") })
    }
}

private struct RecordingTranslator: TranscriptTranslating {
    let providerName = "stub"
    let source = OSAllocatedUnfairLock<String??>(initialState: nil)

    func translate(
        _ texts: [(id: Int, text: String)], from source: String?, to target: String
    ) async throws -> [Int: String] {
        self.source.withLock { $0 = source }
        return Dictionary(uniqueKeysWithValues: texts.map { ($0.id, "T\($0.id)") })
    }
}

@MainActor
@Suite("Translation coordinator", .serialized)
struct TranslationCoordinatorTests {

    private func transcript(segments count: Int, language: String = "it") -> Transcript {
        Transcript(
            segments: (0..<count).map {
                TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: "riga \($0)")
            },
            language: language,
            modelName: "stub"
        )
    }

    @Test("a second run is refused while one is in flight")
    func oneRunAtATime() async {
        let coordinator = TranslationCoordinator()
        let gate = TranslationGate()
        coordinator.translatorOverride = GatedTranslator(gate: gate)

        async let first = coordinator.translate(entryID: "e1", transcript: transcript(segments: 2), to: "en")
        let isRunningWait = await waitUntil { coordinator.isRunning }
        #expect(isRunningWait)

        let second = await coordinator.translate(entryID: "e1", transcript: transcript(segments: 2), to: "fr")
        #expect(second == nil, "the run in flight owns the state until it ends")
        #expect(coordinator.activeTarget == "en")

        await gate.open()
        #expect(await first != nil)
        #expect(coordinator.state == .idle)
    }

    @Test("a session the host never delivers fails instead of waiting forever")
    func sessionWaitIsBounded() async {
        let coordinator = TranslationCoordinator()
        coordinator.sessionWaitBudget = .milliseconds(50)

        // No stub translator and no language of its own: the run takes the Apple path, publishes a
        // configuration, and nothing is on screen to hand a session back.
        let outcome = await coordinator.translate(
            entryID: "e1", transcript: transcript(segments: 2, language: "auto"), to: "en"
        )

        #expect(outcome == nil)
        #expect(coordinator.sessionConfiguration == nil)
        if case .failed(let message) = coordinator.state {
            #expect(message.contains("translator"))
        } else {
            Issue.record("expected a failure, got \(coordinator.state)")
        }
    }

    @Test("the mock translator fills every segment")
    func mockTranslatesEverything() async {
        let coordinator = TranslationCoordinator()
        coordinator.translatorOverride = MockTranslator(mode: .reverseWords)

        let outcome = await coordinator.translate(entryID: "e1", transcript: transcript(segments: 3), to: "en")

        #expect(outcome?.segments == [0: "0 riga", 1: "1 riga", 2: "2 riga"])
        #expect(outcome?.provider == "mock")
        #expect(coordinator.state == .idle)
    }

    @Test("a segment the translator skipped keeps no entry")
    func mapModeLeavesUntranslatedSegmentsOut() async {
        let coordinator = TranslationCoordinator()
        coordinator.translatorOverride = MockTranslator(mode: .map, map: ["riga 1": "line 1"])

        let outcome = await coordinator.translate(entryID: "e1", transcript: transcript(segments: 3), to: "en")

        #expect(outcome?.segments == [1: "line 1"])
    }

    @Test("a transcript with nothing to translate produces no run")
    func emptyTranscriptDoesNothing() async {
        let coordinator = TranslationCoordinator()
        coordinator.translatorOverride = MockTranslator(mode: .reverseWords)
        let blank = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "   ")],
            language: "it",
            modelName: "stub"
        )

        #expect(await coordinator.translate(entryID: "e1", transcript: blank, to: "en") == nil)
        #expect(coordinator.state == .idle)
    }

    @Test("a later batch failing keeps the batches that came back")
    func partialFailureKeepsEarlierBatches() async {
        let coordinator = TranslationCoordinator()
        let translator = FlakyTranslator(failAfter: 1)
        coordinator.translatorOverride = translator

        let outcome = await coordinator.translate(entryID: "e1", transcript: transcript(segments: 70), to: "en")

        #expect(outcome?.segments.count == 60)
        #expect(outcome?.segments[0] == "T0")
        #expect(translator.counter.count == 2)
        guard case .failed(let message) = coordinator.state else {
            Issue.record("expected a failed state, got \(coordinator.state)")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test("a first batch failing translates nothing")
    func firstBatchFailureTranslatesNothing() async {
        let coordinator = TranslationCoordinator()
        coordinator.translatorOverride = FlakyTranslator(failAfter: 0)

        #expect(await coordinator.translate(entryID: "e1", transcript: transcript(segments: 10), to: "en") == nil)
        guard case .failed = coordinator.state else {
            Issue.record("expected a failed state, got \(coordinator.state)")
            return
        }
    }

    @Test("cancelling keeps the batches that already completed")
    func cancelKeepsCompletedBatches() async {
        let coordinator = TranslationCoordinator()
        coordinator.translatorOverride = InterruptingTranslator {
            await MainActor.run { coordinator.cancel() }
        }

        let outcome = await coordinator.translate(entryID: "e1", transcript: transcript(segments: 70), to: "en")

        #expect(outcome?.segments.count == 60)
        #expect(coordinator.state == .idle)
    }

    @Test("progress counts the segments sent so far")
    func progressReportsPerBatch() async {
        let coordinator = TranslationCoordinator()
        let seen = OSAllocatedUnfairLock<[TranslationState]>(initialState: [])
        coordinator.translatorOverride = InterruptingTranslator {
            let state = await MainActor.run { coordinator.state }
            seen.withLock { $0.append(state) }
        }

        _ = await coordinator.translate(entryID: "e1", transcript: transcript(segments: 70), to: "en")

        #expect(seen.withLock { $0 } == [.translating(completed: 0, total: 70), .translating(completed: 60, total: 70)])
        #expect(coordinator.state == .idle)
    }

    @Test("a run belongs to the entry that started it")
    func stateIsScopedToItsEntry() async {
        let coordinator = TranslationCoordinator()
        coordinator.translatorOverride = FlakyTranslator(failAfter: 0)

        _ = await coordinator.translate(entryID: "e1", transcript: transcript(segments: 3), to: "en")

        #expect(coordinator.state(for: "e2") == .idle)
        guard case .failed = coordinator.state(for: "e1") else {
            Issue.record("expected the starting entry to keep the failure")
            return
        }
    }

    @Test("an open source language is left for the framework to detect", arguments: ["auto", "unknown", "", "  "])
    func openSourceLanguageIsNil(_ language: String) async {
        let coordinator = TranslationCoordinator()
        let translator = RecordingTranslator()
        coordinator.translatorOverride = translator

        _ = await coordinator.translate(entryID: "e1", transcript: transcript(segments: 1, language: language), to: "en")

        #expect(translator.source.withLock { $0 } == .some(nil))
    }

    @Test("a known source language is passed through")
    func knownSourceLanguageIsPassed() async {
        let coordinator = TranslationCoordinator()
        let translator = RecordingTranslator()
        coordinator.translatorOverride = translator

        _ = await coordinator.translate(entryID: "e1", transcript: transcript(segments: 1, language: "IT"), to: "en")

        #expect(translator.source.withLock { $0 } == .some("it"))
    }

    @Test("removing another entry's translation leaves the run in flight alone")
    func removeOnAnotherEntryKeepsTheRun() async {
        let coordinator = TranslationCoordinator()
        let seen = OSAllocatedUnfairLock<[TranslationState]>(initialState: [])
        coordinator.translatorOverride = InterruptingTranslator {
            let state = await MainActor.run {
                coordinator.remove(entryID: "B")
                return coordinator.state
            }
            seen.withLock { $0.append(state) }
        }

        let outcome = await coordinator.translate(entryID: "A", transcript: transcript(segments: 70), to: "en")

        #expect(seen.withLock { $0 } == [.translating(completed: 0, total: 70), .translating(completed: 60, total: 70)])
        #expect(outcome?.segments.count == 70)
        #expect(coordinator.state(for: "A") == .idle)
    }

    @Test("a run in flight reports its target and progress to the bridge")
    func runInProgressSnapshot() async {
        let coordinator = TranslationCoordinator()
        let seen = OSAllocatedUnfairLock<[TranslationCoordinator.RunSnapshot]>(initialState: [])
        coordinator.translatorOverride = InterruptingTranslator {
            let snapshot = await MainActor.run { coordinator.runInProgress }
            if let snapshot { seen.withLock { $0.append(snapshot) } }
        }

        _ = await coordinator.translate(entryID: "A", transcript: transcript(segments: 70), to: "en")

        #expect(seen.withLock { $0 }.map(\.segmentCount) == [0, 60])
        #expect(seen.withLock { $0 }.allSatisfy { $0.targetLanguage == "en" && $0.provider == "stub" })
        #expect(coordinator.runInProgress == nil)
    }

    @Test("removing clears the section for the entry that was translating")
    func removeClearsState() async {
        let coordinator = TranslationCoordinator()
        coordinator.translatorOverride = FlakyTranslator(failAfter: 0)

        _ = await coordinator.translate(entryID: "e1", transcript: transcript(segments: 3), to: "en")
        coordinator.remove(entryID: "e1")

        #expect(coordinator.state == .idle)
    }
}

@MainActor
@Suite("Translation through the model", .serialized)
struct AppModelTranslationTests {

    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("translate"))
    }

    private func loadedModel() async throws -> (AppModel, LibraryEntry.ID) {
        let model = makeModel()
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
        return (model, seeded.id)
    }

    @Test("translating writes the transcript and the library bundle")
    func translatePersists() async throws {
        let (model, entryID) = try await loadedModel()
        model.translationCoordinator.translatorOverride = MockTranslator(mode: .reverseWords)

        await model.translateTranscript(to: "EN")

        #expect(model.transcript?.translation?.targetLanguage == "en")
        #expect(model.transcript?.translation?.provider == "mock")
        #expect(model.transcript?.translation?.segments == [0: "mondo ciao", 1: "stai come"])

        let store = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let stored = try await store.load(entryID).document.transcript
        #expect(stored.translation?.segments == [0: "mondo ciao", 1: "stai come"])
    }

    @Test("translating again replaces the previous target")
    func translatingAgainReplaces() async throws {
        let (model, _) = try await loadedModel()
        model.translationCoordinator.translatorOverride = MockTranslator(mode: .reverseWords)

        await model.translateTranscript(to: "en")
        model.translationCoordinator.translatorOverride = MockTranslator(mode: .map, map: ["ciao mondo": "hallo welt"])
        await model.translateTranscript(to: "de")

        #expect(model.transcript?.translation?.targetLanguage == "de")
        #expect(model.transcript?.translation?.segments == [0: "hallo welt"])
    }

    @Test("removing clears the transcript and the library bundle")
    func removePersists() async throws {
        let (model, entryID) = try await loadedModel()
        model.translationCoordinator.translatorOverride = MockTranslator(mode: .reverseWords)
        await model.translateTranscript(to: "en")

        await model.removeTranslation()

        #expect(model.transcript?.translation == nil)
        let store = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        #expect(try await store.load(entryID).document.transcript.translation == nil)
    }

    @Test("side by side is on to begin with and persists")
    func sideBySidePersists() async throws {
        let (model, _) = try await loadedModel()

        #expect(model.translationSideBySide)
        model.translationSideBySide = false
        #expect(model.defaults.bool(forKey: "translationSideBySide") == false)
    }

    @Test("the View menu item stays off until a translation exists")
    func hasTranslationTracksTheTranscript() async throws {
        let (model, _) = try await loadedModel()
        model.translationCoordinator.translatorOverride = MockTranslator(mode: .reverseWords)

        #expect(!model.hasTranslation)
        await model.translateTranscript(to: "en")
        #expect(model.hasTranslation)
        await model.removeTranslation()
        #expect(!model.hasTranslation)
    }

    @Test("a run that finishes after the user moved on still lands in its own bundle")
    func translationPersistsAfterTheUserMovesOn() async throws {
        let (model, entryID) = try await loadedModel()
        model.translationCoordinator.translatorOverride = LeavingTranslator {
            await MainActor.run { model.selectedEntryID = nil }
        }

        await model.translateTranscript(to: "en")

        #expect(model.transcript?.translation == nil)
        let store = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let stored = try await store.load(entryID).document.transcript
        #expect(stored.translation?.segments == [0: "T0", 1: "T1"])
        #expect(stored.translation?.targetLanguage == "en")
    }

    @Test("an installed mock translator is what a run uses")
    func installedMockIsResolved() async throws {
        let (model, _) = try await loadedModel()
        // Unleased on purpose: every other translation test sets translatorOverride, which wins over
        // the registry, so a suite running in parallel cannot resolve what this one installs.
        MockTranslatorRegistry.shared.install(MockTranslator(mode: .map, map: ["come stai": "how are you"]))
        defer { MockTranslatorRegistry.shared.clear() }

        await model.translateTranscript(to: "en")

        #expect(model.transcript?.translation?.segments == [1: "how are you"])
    }
}
