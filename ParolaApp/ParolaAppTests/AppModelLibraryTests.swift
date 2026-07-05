import Foundation
import Testing
@testable import Parola
import ParolaCore

/// A throwaway library directory under the temp dir so tests never touch the real on-disk library.
func makeTempLibraryURL(_ label: String = "appmodel") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("parola-test-\(label)-\(UUID().uuidString)", isDirectory: true)
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
        labels: [String] = []
    ) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(
            createdAt: createdAt,
            originalAudioName: "\(title).m4a",
            modelName: "stub",
            language: "en",
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
        UserDefaults(suiteName: "test-\(UUID())")!
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
}
