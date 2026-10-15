import Foundation
import os
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// A throwaway library directory under the temp dir so tests never touch the real on-disk library.
/// Swept at process exit the way `temporaryDefaults` sweeps its plists: there are 160-odd call
/// sites and every run would otherwise leave that many `.parola` bundles behind.
func makeTempLibraryURL(_ label: String = "appmodel") -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("parola-test-\(label)-\(UUID().uuidString)", isDirectory: true)
    TemporaryLibraries.register(url)
    return url
}

enum TemporaryLibraries {
    private static let registered = OSAllocatedUnfairLock<[URL]>(initialState: [])
    private static let sweepAtExit: Void = { _ = atexit { TemporaryLibraries.discardAll() } }()

    static func register(_ url: URL) {
        _ = sweepAtExit
        registered.withLock { $0.append(url) }
    }

    private static func discardAll() {
        for url in registered.withLock({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }
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

    @Test("loadEntry shuts the find bar the previous entry left open")
    func loadEntryClosesFind() async throws {
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
        model.findIsOpen = true
        model.findQuery = "previous entry"

        model.loadEntry(seeded.id)
        for _ in 0..<200 where model.selectedEntryID != seeded.id {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!model.findIsOpen)
        #expect(model.findQuery.isEmpty)
        #expect(model.matches.isEmpty)
    }

    @Test("a row opened from a search result still lands on its match")
    func loadEntryFromSearchKeepsTheQuery() async throws {
        let model = makeModel()
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let seeded = try await seedStore.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "a quarterly review")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        model.searchRanking = []
        model.searchQuery = "quarterly"

        model.loadEntry(seeded.id)
        for _ in 0..<200 where model.selectedEntryID != seeded.id {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.findIsOpen)
        #expect(model.findQuery == "quarterly")
    }

    @Test("a page opened while an entry loads keeps the window, and the transcript lands behind it")
    func loadEntryLeavesAPageOpenedDuringTheLoad() async throws {
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
        model.openStatistics()
        for _ in 0..<200 where model.selectedEntryID != seeded.id {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.route == .statistics)
        #expect(model.transcript?.segments.first?.text == "hello")
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

    @Test("chapters generated on an entry with no summary are still there after a reload")
    func chaptersWithoutASummarySurviveReload() async throws {
        let model = makeModel()
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let seeded = try await seedStore.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 60, text: "hello")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        model.loadEntry(seeded.id)
        let selectedEntryIDWait = await waitUntil { model.selectedEntryID == seeded.id && model.transcript != nil }
        #expect(selectedEntryIDWait)

        let chapters = [Chapter(title: "Opening", start: 0), Chapter(title: "Wrap up", start: 30)]
        model.smartChapters = chapters
        model.persistChapters(chapters)
        let persistedChaptersMatch = await waitUntil {
            (try? await model.library.load(seeded.id).document.transcript.chapters) == chapters
        }
        #expect(persistedChaptersMatch)

        model.clearLoadedEntry()
        #expect(model.smartChapters.isEmpty)
        model.loadEntry(seeded.id)

        let smartChaptersWait = await waitUntil { model.smartChapters == chapters }
        #expect(smartChaptersWait)
        #expect(model.transcript?.summary == nil)
    }

    @Test("a summary generated after the chapters brings its own, and the reload shows the same list")
    func summaryAfterChaptersKeepsOneList() async throws {
        let model = makeModel()
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let seeded = try await seedStore.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 60, text: "hello")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        model.loadEntry(seeded.id)
        let selectedEntryIDWait = await waitUntil { model.selectedEntryID == seeded.id && model.transcript != nil }
        #expect(selectedEntryIDWait)

        let generated = [Chapter(title: "Generated", start: 0)]
        model.smartChapters = generated
        model.persistChapters(generated)
        let persistedChaptersMatch = await waitUntil {
            (try? await model.library.load(seeded.id).document.transcript.chapters) == generated
        }
        #expect(persistedChaptersMatch)

        let summarized = [Chapter(title: "Opening", start: 0), Chapter(title: "Wrap up", start: 30)]
        model.summariseOperation = { _, _ in Summary(text: "recap", chapters: summarized) }
        model.summariseTranscript()
        let summaryLanded = await waitUntil { !model.isSummarising && model.transcript?.summary != nil }
        #expect(summaryLanded)
        #expect(model.smartChapters == summarized)
        let persistedSummaryChaptersMatch = await waitUntil {
            (try? await model.library.load(seeded.id).document.transcript.chapters) == summarized
        }
        #expect(persistedSummaryChaptersMatch)

        model.clearLoadedEntry()
        model.loadEntry(seeded.id)
        let smartChaptersWait = await waitUntil { model.smartChapters == summarized }
        #expect(smartChaptersWait)
        #expect(model.transcript?.summary?.chapters == summarized)
    }

    @Test("Clear during a regenerate keeps the summary cleared, on screen and on disk")
    func clearDuringRegenerateStaysCleared() async throws {
        let model = makeModel()
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let seeded = try await seedStore.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 60, text: "hello")],
                language: "en",
                modelName: "stub",
                summary: Summary(text: "first recap")
            ),
            audioSource: nil,
            category: .transcription
        )
        model.loadEntry(seeded.id)
        #expect(await waitUntil { model.selectedEntryID == seeded.id && model.transcript?.summary != nil })

        let (release, releaseRun) = AsyncStream<Void>.makeStream()
        let returned = OSAllocatedUnfairLock(initialState: false)
        model.summariseOperation = { _, _ in
            for await _ in release { break }
            returned.withLock { $0 = true }
            return Summary(text: "regenerated recap")
        }
        model.summariseTranscript()
        #expect(model.isSummarising)

        model.clearSummary()
        #expect(model.transcript?.summary == nil)
        #expect(!model.isSummarising)

        releaseRun.yield()
        #expect(await waitUntil { returned.withLock { $0 } })
        await settle()

        #expect(model.transcript?.summary == nil)
        #expect(model.summaryError == nil)
        #expect(await waitUntil {
            (try? await model.library.load(seeded.id).document.transcript).map { $0.summary == nil } == true
        })
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
        model.summariseOperation = { _, _ in Summary(text: "recap") }
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

    @Test("title sort keys off the title the row shows, not the stored one")
    func sortTitleUsesTheDisplayedTitle() {
        let model = makeModel()
        model.librarySortOrder = .titleAZ

        let generic = Self.entry(id: "generic", title: "audio", createdAt: Self.baseDate)
        let sorted = model.sortedLibraryEntries(Self.fixture() + [generic]).map(\.id)

        // "audio" displays as "Recording — …", so it sorts under R, not under a.
        #expect(sorted.firstIndex(of: "generic") ?? 0 > sorted.firstIndex(of: "b") ?? 0)
        #expect(LibraryEntryDisplay.title(for: generic) != "audio")
    }

    @Test("flipping Show AI titles re-sorts a title-sorted library")
    func aiTitleToggleResorts() {
        let model = makeModel()
        var manifest = ParolaDocument.Manifest(
            createdAt: Self.baseDate, originalAudioName: "Mango.m4a", modelName: "stub", language: "en", category: .transcription
        )
        manifest.aiTitle = "Zebra talk"
        let aiTitled = LibraryEntry(id: "ai", bundleURL: URL(fileURLWithPath: "/lib/ai.parola"), manifest: manifest)
        let plain = Self.entry(id: "plain", title: "Nectar", createdAt: Self.baseDate)
        model.librarySortOrder = .titleAZ
        model.showAITitles = true
        model.libraryEntries = model.sortedLibraryEntries([aiTitled, plain])
        #expect(model.libraryEntries.map(\.id) == ["plain", "ai"])

        model.showAITitles = false

        #expect(model.libraryEntries.map(\.id) == ["ai", "plain"])
    }

    @Test("titleZA sort is reverse of A→Z")
    func sortTitleZA() {
        let model = makeModel()
        model.librarySortOrder = .titleZA

        let sorted = model.sortedLibraryEntries(Self.fixture()).map(\.id)

        #expect(sorted == ["c", "a", "b"])
    }

    private static func timedFixture() -> [LibraryEntry] {
        Self.fixture().map { entry in
            var manifest = entry.manifest
            manifest.durationSeconds = ["a": 600, "b": 30, "c": nil][entry.id] ?? nil
            return LibraryEntry(id: entry.id, bundleURL: entry.bundleURL, manifest: manifest)
        }
    }

    @Test("longest sort goes by the length on the row, zero for missing")
    func sortLongest() {
        let model = makeModel()
        model.librarySortOrder = .longest
        model.libraryBundleSizes = ["a": 100, "b": 999, "c": 50]

        let sorted = model.sortedLibraryEntries(Self.timedFixture()).map(\.id)

        #expect(sorted == ["a", "b", "c"])
    }

    @Test("shortest sort goes by the length on the row")
    func sortShortest() {
        let model = makeModel()
        model.librarySortOrder = .shortest
        model.libraryBundleSizes = ["a": 100, "b": 999, "c": 50]

        let sorted = model.sortedLibraryEntries(Self.timedFixture()).map(\.id)

        #expect(sorted == ["c", "b", "a"])
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
        let hit = ["a"]
        let start = model.searchResultsVersion

        model.searchRanking = hit
        #expect(model.searchResultsVersion == start + 1)

        model.searchRanking = hit
        #expect(model.searchResultsVersion == start + 2)

        model.searchRanking = nil
        #expect(model.searchResultsVersion == start + 3)
    }

    @Test("search with an empty query clears searchResults and skips the debounce")
    func searchEmptyQueryClearsResults() {
        let model = makeModel()
        model.searchRanking = ["stale"]

        model.search("   ")

        #expect(model.searchRanking == nil)
    }

    /// A page takes the whole content area, so a query left live behind it is a result set nobody can see.
    @Test("every sidebar destination retires the query behind it")
    func destinationsRetireTheQuery() {
        let destinations: [(String, AppModel.Route, (AppModel) -> Void)] = [
            ("Library", .transcript, { $0.goHome() }),
            ("Library, as browseAll", .transcript, { $0.browseAll() }),
            ("a category", .transcript, { $0.browseCategory(.meeting) }),
            ("Queue", .queue, { $0.openQueue() }),
            ("Batch", .batch, { $0.openBatch() }),
            ("Statistics", .statistics, { $0.openStatistics() }),
            ("Recently Deleted", .recentlyDeleted, { $0.openRecentlyDeleted() }),
        ]
        for (name, route, open) in destinations {
            let model = makeModel()
            model.searchQuery = "bianchi"
            model.searchRanking = ["a"]
            model.libraryOrigin = .search

            open(model)

            #expect(model.route == route, "\(name)")
            #expect(model.searchQuery.isEmpty, "\(name)")
            #expect(model.searchRanking == nil, "\(name)")
            #expect(model.libraryOrigin == nil, "\(name)")
        }
    }

    /// The pane a stale error gated must show whatever the user just asked for instead.
    @Test("every sidebar destination clears a stale failure behind it")
    func destinationsClearTheFailedState() {
        let destinations: [(String, AppModel.Route, (AppModel) -> Void)] = [
            ("Library", .transcript, { $0.goHome() }),
            ("Library, as browseAll", .transcript, { $0.browseAll() }),
            ("a category", .transcript, { $0.browseCategory(.meeting) }),
            ("Queue", .queue, { $0.openQueue() }),
            ("Batch", .batch, { $0.openBatch() }),
            ("Statistics", .statistics, { $0.openStatistics() }),
            ("Recently Deleted", .recentlyDeleted, { $0.openRecentlyDeleted() }),
        ]
        for (name, route, open) in destinations {
            let model = makeModel()
            model.phase = .failed(message: "Couldn't transcribe Voice note 17.m4a")

            open(model)

            #expect(model.route == route, "\(name)")
            #expect(model.phase == .idle, "\(name)")
        }
    }

    @Test("browsing a category after a transcription failure shows the list, not the error card")
    func categoryAfterFailureShowsTheList() {
        let model = makeModel()
        model.phase = .failed(message: "Couldn't transcribe Voice note 17.m4a")

        model.browseCategory(.meeting)

        #expect(model.isBrowsingLibrary)
        #expect(model.libraryFilter == .meeting)
    }

    @Test("a search after a transcription failure clears it and shows results")
    func searchAfterFailureClearsIt() async throws {
        let model = makeModel()
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        _ = try await seedStore.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "banana bread recipe")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        await model.refreshLibraryAndWait()
        model.phase = .failed(message: "Couldn't transcribe Voice note 17.m4a")

        model.search("banana")

        #expect(model.phase == .idle)
        #expect(model.route == .transcript)
        let hasSearchResultsWait = await waitUntil { model.hasSearchResults }
        #expect(hasSearchResultsWait)
    }

    @Test("re-publishing the same query does not clear a failure that just landed")
    func sameQuerySearchDoesNotClearAFailure() {
        let model = makeModel()
        model.search("banana")
        let failure = AppModel.Phase.failed(message: "Couldn't transcribe Voice note 17.m4a")
        model.phase = failure

        model.search("banana")

        #expect(model.phase == failure)
    }

    /// The 7 non-fatal library mutations: none may cost the user their place.
    @Test("a failed label edit, move, pin, rename, delete, restore or purge shows a toast, not a phase change")
    func libraryMutationFailuresDoNotGatePhase() async {
        let mutations: [(String, (AppModel) -> Void)] = [
            ("label edit", { $0.addLabel("x", to: "missing") }),
            ("move", { $0.moveEntry("missing", to: .meeting) }),
            ("pin", { $0.togglePinned(for: "missing") }),
            ("rename", { $0.renameEntry("missing", to: "New name") }),
            ("delete", { $0.deleteEntry("missing") }),
            ("restore", { $0.restoreEntry("missing") }),
            ("purge", { $0.purgeEntry("missing") }),
        ]
        for (name, act) in mutations {
            let model = makeModel()
            model.browseCategory(.meeting)

            act(model)

            let exportNoticeWait = await waitUntil { model.exportNotice != nil }
            #expect(exportNoticeWait, "\(name)")
            #expect(model.phase == .idle, "\(name)")
            #expect(model.libraryFilter == .meeting, "\(name)")
            #expect(model.isBrowsingLibrary, "\(name)")
        }
    }

    @Test("a failed pin on a category list leaves that list on screen")
    func failedPinKeepsTheListOnScreen() async {
        let model = makeModel()
        model.browseCategory(.meeting)

        model.togglePinned(for: "missing-entry")

        let exportNoticeWait = await waitUntil { model.exportNotice != nil }
        #expect(exportNoticeWait)
        #expect(model.libraryFilter == .meeting)
        #expect(model.isBrowsingLibrary)
        #expect(model.phase == .idle)
    }

    @Test("renaming through the model sets a title an AI title cannot outrank")
    func renameBeatsTheAITitle() async throws {
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
        _ = try await seedStore.setCardMetadata(aiTitle: "Generated title", shortSummary: nil, for: seeded.id)
        await model.refreshLibraryAndWait()

        model.renameEntry(seeded.id, to: "My real title")
        let libraryEntryWait = await waitUntil { model.libraryEntry(id: seeded.id)?.manifest.title == "My real title" }
        #expect(libraryEntryWait)

        let renamed = try #require(model.libraryEntry(id: seeded.id))
        #expect(renamed.manifest.titleSource == .user)
        #expect(LibraryEntryDisplay.listTitle(for: renamed, showsAITitle: true) == "My real title")
    }

    @Test("Rename… on an open transcript renames its entry, and the header follows")
    func renameOpenTranscript() async throws {
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
        await model.refreshLibraryAndWait()
        #expect(!model.canRenameOpenTranscript)

        try await model.openEntry(seeded.id)
        #expect(model.canRenameOpenTranscript)

        model.renameOpenTranscript(to: "  Weekly sync  ")
        let renamed = await waitUntil { model.transcriptHeaderTitle == "Weekly sync" }
        #expect(renamed)
        #expect(model.libraryEntry(id: seeded.id)?.manifest.titleSource == .user)
    }

    @Test("LibrarySortOrder exposes a label for every case")
    func sortOrderLabels() {
        for order in LibrarySortOrder.allCases {
            #expect(order.label.isEmpty == false)
            #expect(order.id == order.rawValue)
        }
    }

    /// The menu renders the label through `LocalizedStringKey`, so a label missing from the catalog ships in English.
    @Test("every library sort label resolves to Italian")
    func sortOrderLabelsItalian() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        let expected: [LibrarySortOrder: String] = [
            .newest: "Dal più recente",
            .oldest: "Dal meno recente",
            .titleAZ: "Titolo A→Z",
            .titleZA: "Titolo Z→A",
            .longest: "Dal più lungo",
            .shortest: "Dal più breve",
            .lastOpened: "Ultima apertura",
        ]
        for order in LibrarySortOrder.allCases {
            #expect(italian.localizedString(forKey: order.label, value: "MISSING", table: nil) == expected[order])
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

    @Test("waiters that overlap join the newest refresh instead of restarting each other", .timeLimit(.minutes(1)))
    func overlappingWaitersSettle() async throws {
        let model = makeModel()
        let entry = try await model.library.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hello")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil
        )
        let before = model.libraryRefreshes

        async let first: Void = model.refreshLibraryAndWait()
        async let second: Void = model.refreshLibraryAndWait()
        async let third: Void = model.refreshLibraryAndWait()
        _ = await (first, second, third)

        #expect(model.libraryRefreshes - before <= 4, "\(model.libraryRefreshes - before) scans for three waiters")
        #expect(model.libraryEntries.map(\.id) == [entry.id])
    }

    @Test("rows quote what the index cut, and a refresh that changed nothing leaves the quotes alone")
    func excerptsLandOnceAndStay() async throws {
        let model = makeModel()
        let entry = try await model.library.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "The opening line of the take.")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil
        )
        await model.refreshLibraryAndWait()
        await waitUntil { model.libraryExcerpts[entry.id] != nil }
        #expect(model.libraryExcerpts[entry.id] == "The opening line of the take.")
        let version = model.libraryExcerptsVersion

        await model.refreshLibraryAndWait()
        await model.libraryExcerptsTask?.value
        #expect(model.libraryExcerptsVersion == version)
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

    private func launchWithPurge(_ libraryURL: URL) -> AppModel {
        AppModel(bootstrap: AppBootstrap(
            mode: .test,
            library: libraryURL,
            defaultsOverride: temporaryDefaults(),
            sideEffects: [.libraryPurgeOnLaunch],
            filePicker: SystemFilePicker()
        ))
    }

    @Test("a launch purge with nothing to remove leaves the library list alone")
    func idleLaunchPurgeSkipsTheRefresh() async throws {
        let model = launchWithPurge(makeTempLibraryURL("purge-idle"))
        let refreshes = model.libraryRefreshes

        await model.launchPurgeTask?.value

        #expect(model.libraryRefreshes == refreshes)
    }

    @Test("a launch purge that removed something refreshes the list once")
    func launchPurgeRefreshesAfterRemoving() async throws {
        let libraryURL = makeTempLibraryURL("purge-some")
        let seedStore = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
        let stale = try await seedStore.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "old")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        try await seedStore.delete(stale.id, at: Date().addingTimeInterval(-40 * 86_400))
        let model = launchWithPurge(libraryURL)
        let refreshes = model.libraryRefreshes

        await model.launchPurgeTask?.value
        await model.libraryRefreshTask?.value

        #expect(model.libraryRefreshes == refreshes + 1)
        #expect(model.deletedEntries.isEmpty)
    }

    @Test("coming forward rescans the library only when another process changed its folder")
    func activationRefreshesOnlyWhenChangedElsewhere() async throws {
        let model = makeModel()
        await model.libraryRefreshTask?.value
        let refreshes = model.libraryRefreshes

        await model.refreshLibraryIfChangedElsewhere().value
        #expect(model.libraryRefreshes == refreshes)

        let outside = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let written = try await outside.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "saved from the MCP server")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        await model.refreshLibraryIfChangedElsewhere().value
        await model.libraryRefreshTask?.value

        #expect(model.libraryRefreshes == refreshes + 1)
        #expect(model.libraryEntries.map(\.id) == [written.id])
    }

    @Test("a saved run joins the list and takes the selection with no rescan")
    func landedRunInsertsWithoutRefresh() async throws {
        let model = makeModel()
        await model.libraryRefreshTask?.value
        model.generatesCardMetadata = false
        let older = try await model.library.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "older")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        model.landLibraryEntry(older)
        let refreshes = model.libraryRefreshes
        let listChanges = ObservationFlag()
        let selection = ObservationFlag()
        withObservationTracking {
            _ = model.libraryVersion
        } onChange: {
            listChanges.fired = true
        }
        withObservationTracking {
            _ = model.selectedEntryID
        } onChange: {
            selection.fired = true
        }

        let saved = try await model.land(RunLanding(
            kind: .file,
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "newest")],
                language: "en",
                modelName: "stub"
            )
        )).value
        for _ in 0..<200 where model.selectedEntryID == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.selectedEntryID == saved.id)
        #expect(model.libraryEntries.map(\.id) == [saved.id, older.id])
        #expect(model.libraryRefreshes == refreshes)
        #expect(listChanges.fired && selection.fired)
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

    @Test("goHome unloads the transcript so the Library page can show")
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
        model.personFilter = UUID()

        model.goHome()

        #expect(model.libraryFilter == nil)
        #expect(model.personFilter == nil)
        #expect(model.route == .transcript)
        for _ in 0..<200 where model.transcript != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.transcript == nil)
        #expect(model.selectedEntryID == nil)
        if case .idle = model.phase {} else {
            Issue.record("expected .idle after goHome, got \(model.phase)")
        }
        #expect(model.isBrowsingLibrary)
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
