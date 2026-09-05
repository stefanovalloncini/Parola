import Foundation
import Testing
@testable import Parola
import ParolaCore

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private struct GatedClock: Clock {
    typealias Instant = ContinuousClock.Instant
    let gate: Gate
    var now: Instant { ContinuousClock().now }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        await gate.wait()
        try Task.checkCancellation()
    }
}

private struct ImmediateClock: Clock {
    typealias Instant = ContinuousClock.Instant
    var now: Instant { ContinuousClock().now }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        await Task.yield()
    }
}

@MainActor
@Suite("Debounced transcript persistence")
struct DebouncedPersistenceTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        temporaryDefaults()
    }

    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("debounce"))
    }

    private static func seedEntry(in model: AppModel) async throws -> LibraryEntry {
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        return try await seedStore.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "original")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
    }

    @Test("two rapid edits coalesce into one write")
    func rapidEditsCoalesce() async throws {
        let model = makeModel()
        let entry = try await Self.seedEntry(in: model)
        model.selectedEntryID = entry.id
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "original")],
            language: "en",
            modelName: "stub"
        )

        model.editSegment(id: 0, newText: "edit one")
        model.editSegment(id: 0, newText: "edit two")

        await model.flushPendingTranscriptSave()

        let loaded = try await model.library.load(entry.id)
        #expect(loaded.document.transcript.segments[0].text == "edit two")
    }

    @Test("flush on entry switch persists the last edit")
    func flushOnEntrySwitch() async throws {
        let model = makeModel()
        let entry = try await Self.seedEntry(in: model)
        model.selectedEntryID = entry.id
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "original")],
            language: "en",
            modelName: "stub"
        )

        model.editSegment(id: 0, newText: "edited before switch")

        let entry2 = try await Self.seedEntry(in: model)
        model.loadEntry(entry2.id)
        var switched = false
        for _ in 0..<200 {
            if model.selectedEntryID == entry2.id { switched = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(switched)

        let loaded = try await model.library.load(entry.id)
        #expect(loaded.document.transcript.segments[0].text == "edited before switch")
    }

    @Test("timing-only nudge does not trigger a search re-index")
    func timingNudgeSkipsReindex() async throws {
        let store = LibraryStore(libraryURL: makeTempLibraryURL("reindex"), extraIndexer: nil)
        let entry = try await store.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hello world")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        let before = await store.search("hello")
        #expect(before.count == 1)

        let nudged = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0.1, end: 1.1, text: "hello world")],
            language: "en",
            modelName: "stub"
        )
        try await store.updateTranscript(nudged, for: entry.id, reindex: false)

        let after = await store.search("hello")
        #expect(after.count == 1)
    }

    @Test("text edit still triggers re-index")
    func textEditReindexes() async throws {
        let store = LibraryStore(libraryURL: makeTempLibraryURL("reindex2"), extraIndexer: nil)
        let entry = try await store.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hello world")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )

        let updated = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "goodbye universe")],
            language: "en",
            modelName: "stub"
        )
        try await store.updateTranscript(updated, for: entry.id, reindex: true)

        let helloResults = await store.search("hello")
        let goodbyeResults = await store.search("goodbye")
        #expect(helloResults.count == 0)
        #expect(goodbyeResults.count == 1)
    }

    private func makeImmediateModel() -> AppModel {
        let bootstrap = AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("debounce-immediate"),
            defaultsOverride: makeIsolatedDefaults(),
            sideEffects: [],
            filePicker: TestFilePicker(),
            clock: ImmediateClock()
        )
        return AppModel(bootstrap: bootstrap)
    }

    @Test("text edit followed by timing nudge still reindexes when timer fires")
    func textEditThenNudgeReindexesViaTimer() async throws {
        let model = makeImmediateModel()
        let entry = try await Self.seedEntry(in: model)
        model.selectedEntryID = entry.id
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "original")],
            language: "en",
            modelName: "stub"
        )

        // text edit (textChanged: true) followed by a timing nudge (textChanged: false)
        // both within the coalesce window; the nudge reschedules with textChanged: false,
        // which without the sticky flag causes the coalesced write to skip reindex
        model.editSegment(id: 0, newText: "kryptonite")
        model.nudgeSegmentEnd(id: 0, frames: 1)

        // Wait for the ImmediateClock debounce task to fire and complete
        for _ in 0..<50 {
            if model.pendingTranscriptSaveTask == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.pendingTranscriptSaveTask == nil, "debounce task should have fired")

        let results = await model.library.search("kryptonite")
        #expect(results.count == 1, "search index must reflect the text edit even when the final coalesced call was a timing nudge")
    }

    private func manifestDuration(of entry: LibraryEntry) -> Double? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: entry.bundleURL.appendingPathComponent("manifest.json")),
              let manifest = try? decoder.decode(ParolaDocument.Manifest.self, from: data)
        else { return nil }
        return manifest.durationSeconds
    }

    @Test("a duration correction is not undone by an edit save already waiting")
    func correctedDurationOutlivesPendingEdit() async throws {
        let gate = Gate()
        let model = AppModel(bootstrap: AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("debounce-gated"),
            defaultsOverride: makeIsolatedDefaults(),
            sideEffects: [],
            filePicker: TestFilePicker(),
            clock: GatedClock(gate: gate)
        ))
        let stale = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "original")],
            language: "en",
            modelName: "stub",
            durationSeconds: 2134.272
        )
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let entry = try await seedStore.add(transcript: stale, audioSource: nil, category: .transcription)
        model.selectedEntryID = entry.id
        model.transcript = stale

        model.editSegment(id: 0, newText: "edited")
        model.mediaDurationSeconds = 12
        model.adoptLoadedMediaDuration()

        var corrected = false
        for _ in 0..<200 {
            if abs((manifestDuration(of: entry) ?? 0) - 12) < 0.05 { corrected = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(corrected, "manifest says \(String(describing: manifestDuration(of: entry)))")

        await gate.open()
        for _ in 0..<200 {
            if model.pendingTranscriptSaveTask == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.pendingTranscriptSaveTask == nil, "debounce task should have fired")

        let loaded = try await model.library.load(entry.id)
        #expect(loaded.document.transcript.segments[0].text == "edited")
        #expect(
            abs((manifestDuration(of: entry) ?? 0) - 12) < 0.05,
            "manifest says \(String(describing: manifestDuration(of: entry)))"
        )
    }
}
