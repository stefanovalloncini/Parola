import Foundation
import Testing
@testable import Parola
import ParolaCore

/// A throwaway library directory under the temp dir so tests never touch the real on-disk library.
func makeTempLibraryURL(_ label: String = "appmodel") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("parola-test-\(label)-\(UUID().uuidString)", isDirectory: true)
}

// @unchecked: only written from the observation callback, which the library refresh raises on the main actor.
private final class ObservationFlag: @unchecked Sendable {
    var fired = false
}

@MainActor
@Suite("AppModel library")
struct AppModelLibraryTests {

    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static func entry(
        id: String,
        title: String,
        createdAt: Date,
        lastOpenedAt: Date? = nil,
        labels: [String] = [],
        language: String = "en",
        category: EntryCategory = .transcription
    ) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(
            createdAt: createdAt,
            originalAudioName: "\(title).m4a",
            modelName: "stub",
            language: language,
            category: category,
            lastOpenedAt: lastOpenedAt,
            labels: labels
        )
        let bundleURL = URL(fileURLWithPath: "/tmp/AppModelLibraryTests/\(id).parola")
        return LibraryEntry(id: id, bundleURL: bundleURL, manifest: manifest)
    }

    private static func fixture() -> [LibraryEntry] {
        [
            entry(id: "a", title: "Banana", createdAt: baseDate.addingTimeInterval(100)),
            entry(id: "b", title: "apple", createdAt: baseDate.addingTimeInterval(200)),
            entry(id: "c", title: "Cherry", createdAt: baseDate.addingTimeInterval(300)),
        ]
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        temporaryDefaults()
    }

    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("library"))
    }

    @Test("convenience init routes libraryURL to the store instead of the real library")
    func libraryURLIsIsolated() {
        let tmp = makeTempLibraryURL("isolated")
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: tmp)
        #expect(model.library.libraryURL == tmp)
        #expect(model.library.libraryURL != LibraryStore.defaultLibraryURL)
    }

    @Test("loadEntry sets selectedEntryID so the detail features bind to the opened entry")
    func loadEntrySetsSelectedID() async throws {
        let model = makeModel()
        // Seed via a no-Spotlight store sharing the model's library dir; the real CSSearchableIndex call inside add() can hang in the test host.
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let seeded = try await seedStore.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hello")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        model.selectedEntryID = nil

        model.loadEntry(seeded.id)
        var loaded = false
        for _ in 0..<200 {
            if model.selectedEntryID == seeded.id { loaded = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(loaded)
        #expect(model.transcript?.segments.first?.text == "hello")
    }

    @Test("loadEntry clears artifacts derived from the previous transcript")
    func loadEntryClearsDerivedArtifacts() async throws {
        let model = makeModel()
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let seeded = try await seedStore.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hello")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        model.promptOutput = AppModel.PromptOutput(promptName: "p", text: "stale")
        model.actionItems = [ActionItem(task: "stale task")]
        model.smartChapters = [Chapter(title: "stale chapter", start: 0)]

        model.loadEntry(seeded.id)
        for _ in 0..<200 where model.selectedEntryID != seeded.id {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.selectedEntryID == seeded.id)
        #expect(model.promptOutput == nil)
        #expect(model.actionItems.isEmpty)
        #expect(model.smartChapters.isEmpty)
    }

    private static func transcriptWithSavedChapters(
        _ chapters: [Chapter] = [Chapter(title: "Opening", start: 0), Chapter(title: "Wrap up", start: 40)]
    ) -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hello")],
            language: "en",
            modelName: "stub",
            summary: Summary(text: "recap", chapters: chapters)
        )
    }

    @Test("loadEntry seeds smartChapters from the saved summary")
    func loadEntryAdoptsSavedChapters() async throws {
        let model = makeModel()
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let seeded = try await seedStore.add(
            transcript: Self.transcriptWithSavedChapters(),
            audioSource: nil,
            category: .transcription
        )

        model.loadEntry(seeded.id)
        for _ in 0..<200 where model.selectedEntryID != seeded.id {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.smartChapters.map(\.title) == ["Opening", "Wrap up"])
    }

    @Test("loadEntry leaves smartChapters empty when the entry saved none")
    func loadEntryWithoutSavedChaptersLeavesChaptersEmpty() async throws {
        let model = makeModel()
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let seeded = try await seedStore.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hello")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        model.smartChapters = [Chapter(title: "stale chapter", start: 0)]

        model.loadEntry(seeded.id)
        for _ in 0..<200 where model.selectedEntryID != seeded.id {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.smartChapters.isEmpty)
    }

    @Test("cleared chapters stay cleared after closing and reopening the entry")
    func clearedChaptersDoNotComeBackOnReload() async throws {
        let model = makeModel()
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let seeded = try await seedStore.add(
            transcript: Self.transcriptWithSavedChapters(),
            audioSource: nil,
            category: .transcription
        )

        model.loadEntry(seeded.id)
        for _ in 0..<200 where model.selectedEntryID != seeded.id {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.smartChapters.map(\.title) == ["Opening", "Wrap up"])

        model.clearSmartChapters()
        #expect(model.smartChapters.isEmpty)

        var persisted = false
        for _ in 0..<200 {
            let stored = try? await model.library.load(seeded.id).document.transcript
            if stored?.summary?.chapters.isEmpty == true { persisted = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(persisted)

        model.clearLoadedEntry()
        model.loadEntry(seeded.id)
        for _ in 0..<200 where model.selectedEntryID != seeded.id {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.smartChapters.isEmpty)
    }

    @Test("summarizing the latest entry adopts its chapters, not the previous entry's")
    func summarizeLatestEntryAdoptsItsOwnChapters() async throws {
        // Seed before the model exists: its init primes the store's list cache, and an empty one never refills.
        let libraryURL = makeTempLibraryURL("summarize-latest")
        let seedStore = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
        let seeded = try await seedStore.add(
            transcript: Self.transcriptWithSavedChapters(),
            audioSource: nil,
            category: .transcription
        )
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: libraryURL)
        model.summariseOperation = { _ in Summary(text: "recap") }
        model.smartChapters = [Chapter(title: "stale chapter", start: 0)]

        model.summarizeLatestEntry()
        for _ in 0..<200 where model.selectedEntryID != seeded.id {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.selectedEntryID == seeded.id)
        #expect(model.smartChapters.map(\.title) == ["Opening", "Wrap up"])
    }

    @Test("clearing the loaded entry drops the adopted chapters")
    func clearLoadedEntryDropsAdoptedChapters() {
        let model = makeModel()
        model.transcript = Self.transcriptWithSavedChapters([Chapter(title: "Opening", start: 0)])
        model.adoptSavedChapters()
        #expect(!model.smartChapters.isEmpty)

        model.clearLoadedEntry()

        #expect(model.smartChapters.isEmpty)
    }

    @Test("newest sort orders by createdAt descending")
    func sortNewest() {
        let model = makeModel()
        model.librarySortOrder = .newest

        let sorted = model.sortedLibraryEntries(Self.fixture()).map(\.id)

        #expect(sorted == ["c", "b", "a"])
    }

    @Test("oldest sort orders by createdAt ascending")
    func sortOldest() {
        let model = makeModel()
        model.librarySortOrder = .oldest

        let sorted = model.sortedLibraryEntries(Self.fixture()).map(\.id)

        #expect(sorted == ["a", "b", "c"])
    }

    @Test("titleAZ sort uses case-insensitive comparison")
    func sortTitleAZ() {
        let model = makeModel()
        model.librarySortOrder = .titleAZ

        let sorted = model.sortedLibraryEntries(Self.fixture()).map(\.id)

        #expect(sorted == ["b", "a", "c"])
    }

    @Test("titleZA sort is reverse of A→Z")
    func sortTitleZA() {
        let model = makeModel()
        model.librarySortOrder = .titleZA

        let sorted = model.sortedLibraryEntries(Self.fixture()).map(\.id)

        #expect(sorted == ["c", "a", "b"])
    }

    @Test("longest sort uses bundle sizes, biggest first, zero for missing")
    func sortLongest() {
        let model = makeModel()
        model.librarySortOrder = .longest
        model.libraryBundleSizes = ["a": 100, "b": 999, "c": 50]

        let sorted = model.sortedLibraryEntries(Self.fixture()).map(\.id)

        #expect(sorted == ["b", "a", "c"])
    }

    @Test("shortest sort uses bundle sizes, smallest first")
    func sortShortest() {
        let model = makeModel()
        model.librarySortOrder = .shortest
        model.libraryBundleSizes = ["a": 100, "b": 999, "c": 50]

        let sorted = model.sortedLibraryEntries(Self.fixture()).map(\.id)

        #expect(sorted == ["c", "a", "b"])
    }

    @Test("bundle sizing prefers the manifest's audio file and falls back to the listing")
    func audioSizeUsesManifestName() throws {
        let bundle = makeTempLibraryURL("audio-size").appendingPathComponent("entry.parola")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try Data(count: 10).write(to: bundle.appendingPathComponent("audio.mp3"))
        try Data(count: 40).write(to: bundle.appendingPathComponent("audio.wav"))

        #expect(AppModel.audioSize(inBundle: bundle, named: "audio.wav") == 40)
        #expect(AppModel.audioSize(inBundle: bundle, named: "audio.mp3") == 10)
        #expect(AppModel.audioSize(inBundle: bundle, named: "audio.gone") == 10)
        #expect(AppModel.audioSize(inBundle: bundle, named: nil) == 10)
    }

    @Test("bundle sizing reports zero when the bundle holds no audio")
    func audioSizeWithoutAudio() throws {
        let bundle = makeTempLibraryURL("audio-size-none").appendingPathComponent("entry.parola")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try Data(count: 5).write(to: bundle.appendingPathComponent("transcript.json"))

        #expect(AppModel.audioSize(inBundle: bundle, named: nil) == 0)
        #expect(AppModel.audioSize(inBundle: bundle, named: "audio.wav") == 0)
    }

    @Test("lastOpened sort puts opened entries first, then unopened by createdAt desc")
    func sortLastOpened() {
        let entries = [
            Self.entry(id: "a", title: "A", createdAt: Self.baseDate),
            Self.entry(id: "b", title: "B", createdAt: Self.baseDate.addingTimeInterval(100), lastOpenedAt: Self.baseDate.addingTimeInterval(1000)),
            Self.entry(id: "c", title: "C", createdAt: Self.baseDate.addingTimeInterval(200), lastOpenedAt: Self.baseDate.addingTimeInterval(2000)),
            Self.entry(id: "d", title: "D", createdAt: Self.baseDate.addingTimeInterval(50)),
        ]
        let model = makeModel()
        model.librarySortOrder = .lastOpened

        let sorted = model.sortedLibraryEntries(entries).map(\.id)

        #expect(sorted.prefix(2) == ["c", "b"])
        #expect(sorted.suffix(2) == ["d", "a"])
    }

    @Test("changing sort order reapplies the sort onto libraryEntries")
    func sortChangeReappliesOrder() {
        let model = makeModel()
        model.libraryEntries = Self.fixture()

        model.librarySortOrder = .titleAZ

        #expect(model.libraryEntries.map(\.id) == ["b", "a", "c"])
    }

    @Test("allKnownLabels deduplicates by exact value and sorts case-insensitively")
    func knownLabels() {
        let entries = [
            Self.entry(id: "1", title: "x", createdAt: Self.baseDate, labels: ["zeta", "Alpha"]),
            Self.entry(id: "2", title: "y", createdAt: Self.baseDate, labels: ["Alpha", "Beta"]),
            Self.entry(id: "3", title: "z", createdAt: Self.baseDate, labels: []),
        ]
        let model = makeModel()
        model.libraryEntries = entries

        let labels = model.allKnownLabels

        #expect(labels == ["Alpha", "Beta", "zeta"])
    }

    @Test("allKnownLabels is empty when no entry has labels")
    func knownLabelsEmpty() {
        let model = makeModel()
        model.libraryEntries = [Self.entry(id: "1", title: "x", createdAt: Self.baseDate)]

        #expect(model.allKnownLabels.isEmpty)
    }

    @Test("allKnownLabels picks up a relabelled entry")
    func knownLabelsFollowMutations() {
        let model = makeModel()
        model.libraryEntries = [Self.entry(id: "1", title: "x", createdAt: Self.baseDate, labels: ["draft"])]
        #expect(model.allKnownLabels == ["draft"])

        model.libraryEntries = [Self.entry(id: "1", title: "x", createdAt: Self.baseDate, labels: ["draft", "final"])]

        #expect(model.allKnownLabels == ["draft", "final"])
    }

    @Test("knownLanguages deduplicates the codes the entries carry and sorts them")
    func knownLanguages() {
        let model = makeModel()
        model.libraryEntries = [
            Self.entry(id: "1", title: "x", createdAt: Self.baseDate, language: "it"),
            Self.entry(id: "2", title: "y", createdAt: Self.baseDate, language: "IT"),
            Self.entry(id: "3", title: "z", createdAt: Self.baseDate, language: "en"),
            Self.entry(id: "4", title: "w", createdAt: Self.baseDate, language: ""),
        ]

        #expect(model.knownLanguages(in: nil) == ["EN", "IT"])
    }

    @Test("knownLanguages follows the library instead of a stale cache")
    func knownLanguagesFollowMutations() {
        let model = makeModel()
        model.libraryEntries = [Self.entry(id: "1", title: "x", createdAt: Self.baseDate, language: "en")]
        #expect(model.knownLanguages(in: nil) == ["EN"])

        model.libraryEntries = [Self.entry(id: "1", title: "x", createdAt: Self.baseDate, language: "fr")]

        #expect(model.knownLanguages(in: nil) == ["FR"])
    }

    @Test("the filter vocabulary only offers what the category itself uses")
    func vocabularyIsScopedToTheCategory() {
        let model = makeModel()
        model.libraryEntries = [
            Self.entry(id: "1", title: "x", createdAt: Self.baseDate, labels: ["draft"], language: "it"),
            Self.entry(id: "2", title: "y", createdAt: Self.baseDate, labels: ["recap"], language: "en", category: .meeting),
        ]

        #expect(model.knownLabels(in: .meeting) == ["recap"])
        #expect(model.knownLanguages(in: .meeting) == ["EN"])
        #expect(model.knownLabels(in: .transcription) == ["draft"])
        #expect(model.knownLanguages(in: .dictation).isEmpty)
        #expect(model.knownLabels(in: nil) == ["draft", "recap"])
        // The inspector suggests every label in the library, whatever category the entry sits in.
        #expect(model.allKnownLabels == ["draft", "recap"])
    }

    @Test("the per-category vocabulary is dropped when the library changes")
    func vocabularyFollowsMutations() {
        let model = makeModel()
        model.libraryEntries = [Self.entry(id: "1", title: "x", createdAt: Self.baseDate, labels: ["recap"], category: .meeting)]
        #expect(model.knownLabels(in: .meeting) == ["recap"])

        model.libraryEntries = [Self.entry(id: "1", title: "x", createdAt: Self.baseDate, labels: ["agenda"], category: .meeting)]

        #expect(model.knownLabels(in: .meeting) == ["agenda"])
    }

    @Test("the search debounce stays short enough to feel immediate")
    func searchDebounceIsShort() {
        #expect(AppModel.searchDebounce == .milliseconds(70))
    }

    /// The bridge's search waiter counts versions rather than clearing the results first, so a repeat query has to bump it too.
    @Test("every search result assignment is a new version")
    func searchResultsVersionBumps() {
        let model = makeModel()
        let hit = [Self.entry(id: "a", title: "A", createdAt: Self.baseDate)]
        let start = model.searchResultsVersion

        model.searchResults = hit
        #expect(model.searchResultsVersion == start + 1)

        model.searchResults = hit
        #expect(model.searchResultsVersion == start + 2)

        model.searchResults = nil
        #expect(model.searchResultsVersion == start + 3)
    }

    @Test("search with an empty query clears searchResults and skips the debounce")
    func searchEmptyQueryClearsResults() {
        let model = makeModel()
        model.searchResults = [Self.entry(id: "stale", title: "stale", createdAt: Self.baseDate)]

        model.search("   ")

        #expect(model.searchResults == nil)
    }

    @Test("LibrarySortOrder exposes a label for every case")
    func sortOrderLabels() {
        for order in LibrarySortOrder.allCases {
            #expect(order.label.isEmpty == false)
            #expect(order.id == order.rawValue)
        }
    }

    @Test("LibrarySortOrder cases are all distinct")
    func sortOrderRawsUnique() {
        let raws = LibrarySortOrder.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
    }

    @Test("refreshLibrary cancels any prior in-flight refresh so a stale snapshot can't win")
    func refreshLibraryCancelsPrior() {
        let model = makeModel()

        model.refreshLibrary()
        let first = model.libraryRefreshTask
        model.refreshLibrary()

        #expect(first?.isCancelled == true)
    }

    @Test("a superseded refresh does not overwrite libraryEntries with its stale snapshot")
    func cancelledRefreshDoesNotClobber() async throws {
        let model = makeModel()
        let fresh = Self.entry(id: "fresh", title: "Fresh", createdAt: Self.baseDate)
        model.libraryEntries = [fresh]

        model.refreshLibrary()
        model.libraryRefreshTask?.cancel()
        await model.libraryRefreshTask?.value

        #expect(model.libraryEntries.map(\.id) == ["fresh"])
    }

    @Test("saving a segment note invalidates the observed path the segment card reads")
    func segmentNoteIsObserved() async throws {
        let model = makeModel()
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let seeded = try await seedStore.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hello")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        model.selectedEntryID = seeded.id

        let invalidated = ObservationFlag()
        withObservationTracking {
            _ = model.currentSegmentNote(for: 0)
        } onChange: {
            invalidated.fired = true
        }

        model.setSegmentNote("check the mix", segmentID: 0)
        for _ in 0..<200 where model.currentSegmentNote(for: 0) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(invalidated.fired)
        #expect(model.currentSegmentNote(for: 0) == "check the mix")
    }

    @Test("goHome unloads the transcript so the launcher can render under the Home row")
    func goHomeUnloadsTranscript() async throws {
        let model = makeModel()
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let seeded = try await seedStore.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hello")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        model.loadEntry(seeded.id)
        for _ in 0..<200 where model.selectedEntryID != seeded.id {
            try await Task.sleep(for: .milliseconds(10))
        }
        model.libraryFilter = .meeting
        model.libraryBrowsingAll = true

        model.goHome()

        #expect(model.libraryFilter == nil)
        #expect(model.libraryBrowsingAll == false)
        #expect(model.route == .transcript)
        for _ in 0..<200 where model.transcript != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.transcript == nil)
        #expect(model.selectedEntryID == nil)
        if case .idle = model.phase {} else {
            Issue.record("expected .idle after goHome, got \(model.phase)")
        }
    }

    @Test("goHome flushes a debounced transcript edit instead of dropping it")
    func goHomeFlushesPendingEdit() async throws {
        let model = makeModel()
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let seeded = try await seedStore.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "before")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        model.loadEntry(seeded.id)
        for _ in 0..<200 where model.selectedEntryID != seeded.id {
            try await Task.sleep(for: .milliseconds(10))
        }

        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "after")],
            language: "en",
            modelName: "stub"
        )
        model.persistCurrentTranscriptIfLoaded()
        model.goHome()

        for _ in 0..<300 where model.transcript != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Fresh store: seedStore caches the loaded document, which would hide the write.
        let readBack = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let reloaded = try await readBack.load(seeded.id)
        #expect(reloaded.document.transcript.segments.first?.text == "after")
    }

    @Test("goHome leaves a run in flight alone")
    func goHomeKeepsRunningWork() {
        let model = makeModel()
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "partial")],
            language: "en",
            modelName: "stub"
        )
        model.phase = .transcribing(file: URL(fileURLWithPath: "/tmp/clip.wav"))

        model.goHome()

        #expect(model.transcript != nil)
        if case .transcribing = model.phase {} else {
            Issue.record("expected the transcribing phase to survive goHome, got \(model.phase)")
        }
    }
}
