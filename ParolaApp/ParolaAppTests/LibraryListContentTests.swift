import AppKit
import Foundation
import SwiftUI
import Testing
import ParolaCore
@testable import Parola

@MainActor
@Suite("Library list content")
struct LibraryListContentTests {
    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(
        id: String,
        title: String,
        offset: TimeInterval,
        pinned: Bool = false,
        category: EntryCategory = .transcription,
        labels: [String] = [],
        language: String = "en"
    ) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(
            createdAt: Self.baseDate.addingTimeInterval(offset),
            originalAudioName: "\(title).m4a",
            title: title,
            modelName: "stub",
            language: language,
            category: category,
            labels: labels,
            pinned: pinned
        )
        return LibraryEntry(
            id: id,
            bundleURL: URL(fileURLWithPath: "/tmp/LibraryListContentTests/\(id).parola"),
            manifest: manifest
        )
    }

    private func rows(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        LibraryListContent.rows(
            from: entries,
            category: nil,
            labelFilter: nil,
            languageFilter: nil,
            dateRange: .all
        )
    }

    /// AppModel's init kicks off a library refresh; letting it land keeps it from clobbering the seeded entries.
    private func makeModel() async -> AppModel {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("listcontent")
        )
        await model.libraryRefreshTask?.value
        return model
    }

    @Test("keeps the order the model sorted the entries into")
    func keepsModelOrder() {
        let sorted = [
            entry(id: "a", title: "Apple", offset: 100),
            entry(id: "b", title: "Banana", offset: 300),
            entry(id: "c", title: "Cherry", offset: 200),
        ]
        #expect(rows(sorted).map(\.id) == ["a", "b", "c"])
    }

    @Test("the sidebar sort order drives the rendered list")
    func sortOrderDrivesList() async {
        let model = await makeModel()
        model.libraryEntries = [
            entry(id: "a", title: "Banana", offset: 100),
            entry(id: "b", title: "apple", offset: 300),
            entry(id: "c", title: "Cherry", offset: 200),
        ]

        model.librarySortOrder = .titleAZ
        #expect(rows(model.libraryEntries).map(\.id) == ["b", "a", "c"])

        model.librarySortOrder = .oldest
        #expect(rows(model.libraryEntries).map(\.id) == ["a", "c", "b"])

        model.librarySortOrder = .newest
        #expect(rows(model.libraryEntries).map(\.id) == ["b", "c", "a"])
    }

    @Test("pinned entries stay on top without reshuffling the rest")
    func pinnedStayOnTop() async {
        let model = await makeModel()
        model.libraryEntries = [
            entry(id: "a", title: "Banana", offset: 100),
            entry(id: "b", title: "apple", offset: 300, pinned: true),
            entry(id: "c", title: "Cherry", offset: 200),
            entry(id: "d", title: "Date", offset: 400, pinned: true),
        ]

        model.librarySortOrder = .titleAZ
        #expect(rows(model.libraryEntries).map(\.id) == ["b", "d", "a", "c"])
    }

    @Test("filters by category, label, language and date range")
    func filters() {
        let entries = [
            entry(id: "a", title: "Alpha", offset: 100, labels: ["work"]),
            entry(id: "b", title: "Beta", offset: 200, category: .meeting, labels: ["Work"]),
            entry(id: "c", title: "Gamma", offset: 300, language: "it"),
        ]

        let byCategory = LibraryListContent.rows(
            from: entries, category: .meeting, labelFilter: nil, languageFilter: nil, dateRange: .all
        )
        #expect(byCategory.map(\.id) == ["b"])

        let byLabel = LibraryListContent.rows(
            from: entries, category: nil, labelFilter: "work", languageFilter: nil, dateRange: .all
        )
        #expect(byLabel.map(\.id) == ["a", "b"])

        let byLanguage = LibraryListContent.rows(
            from: entries, category: nil, labelFilter: nil, languageFilter: "IT", dateRange: .all
        )
        #expect(byLanguage.map(\.id) == ["c"])

        let byDate = LibraryListContent.rows(
            from: entries, category: nil, labelFilter: nil, languageFilter: nil, dateRange: .today
        )
        #expect(byDate.isEmpty)
    }

    @Test("search results take the list over from whatever category was showing")
    func searchResultsWinOverTheFilter() {
        #expect(LibraryListContent.browseCategory(filter: .meeting, searching: false) == .meeting)
        #expect(LibraryListContent.browseCategory(filter: .meeting, searching: true) == nil)
        #expect(LibraryListContent.browseCategory(filter: nil, searching: true) == nil)
        #expect(LibraryListContent.browseCategory(filter: nil, searching: false) == nil)
    }

    /// The list now survives sidebar moves, so what a category switch leaves behind is what the user keeps.
    @Test("a category switch narrows the rows and drops the selection that left with them")
    func categorySwitchKeepsOnlyTheSurvivingSelection() {
        let entries = [
            entry(id: "a", title: "Alpha", offset: 100),
            entry(id: "b", title: "Beta", offset: 200, category: .meeting),
            entry(id: "c", title: "Gamma", offset: 300, category: .meeting),
        ]
        func ids(_ category: EntryCategory?) -> Set<LibraryEntry.ID> {
            Set(LibraryListContent.rows(
                from: entries, category: category, labelFilter: nil, languageFilter: nil, dateRange: .all
            ).map(\.id))
        }

        var selection: Set<LibraryEntry.ID> = ["a", "b"]
        selection.formIntersection(ids(.meeting))
        #expect(selection == ["b"])

        selection.formIntersection(ids(.transcription))
        #expect(selection.isEmpty)

        selection = ["a", "b", "c"]
        selection.formIntersection(ids(nil))
        #expect(selection == ["a", "b", "c"])
    }

    private func rowHeight(density: String, style: LibraryRow.Style) async -> CGFloat {
        let model = await makeModel()
        model.sidebarDensity = density
        let display = LibraryRowDisplay(entry: entry(id: "a", title: "Alpha", offset: 0), sizeBytes: 1_000_000)
        let host = NSHostingView(rootView: LibraryRow(display: display, style: style).environment(model))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 200)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// The home style carries the same content without the declared height, so it measures what the library row
    /// is pinned to. Comparing the two is what can fail: asserting the library row's own constant cannot.
    @Test("the declared library row height is the height the row would have measured")
    func rowHeightMatchesMeasuredContent() async {
        let comfortable = await rowHeight(density: "comfortable", style: .home)
        let compact = await rowHeight(density: "compact", style: .home)

        #expect(comfortable == 39)
        #expect(compact == 35)
        #expect(await rowHeight(density: "comfortable", style: .library) == comfortable)
        #expect(await rowHeight(density: "compact", style: .library) == compact)
        #expect(comfortable - compact == DS.Spacing.tight)
    }

    private func mixedLibrary() -> [LibraryEntry] {
        [
            entry(id: "t1", title: "Alpha", offset: 100, labels: ["draft"], language: "it"),
            entry(id: "t2", title: "Beta", offset: 200, labels: ["draft", "shared"], language: "en"),
            entry(id: "m1", title: "Gamma", offset: 300, category: .meeting, labels: ["recap"], language: "en"),
            entry(id: "m2", title: "Delta", offset: 400, category: .meeting, labels: ["shared"], language: "en"),
        ]
    }

    @Test("a filter the new category has no row for is dropped on the way in")
    func filtersDroppedOnCategorySwitch() {
        let entries = mixedLibrary()
        let carried = LibraryListContent.ActiveFilters(label: "draft", language: "IT", dateRange: .today)

        let intoMeetings = LibraryListContent.filters(carried, survivingIn: .meeting, entries: entries)
        #expect(intoMeetings == LibraryListContent.ActiveFilters())

        let kept = LibraryListContent.filters(
            LibraryListContent.ActiveFilters(label: "shared", language: "EN"),
            survivingIn: .meeting,
            entries: entries
        )
        #expect(kept.label == "shared")
        #expect(kept.language == "EN")
    }

    @Test("a filter that survives on its own is kept even when combined it matches nothing")
    func combinedFiltersAreLeftToTheEmptyState() {
        let kept = LibraryListContent.filters(
            LibraryListContent.ActiveFilters(label: "recap", language: "IT"),
            survivingIn: .meeting,
            entries: mixedLibrary()
        )

        #expect(kept.label == "recap")
        #expect(kept.language == nil)
    }

    @Test("an empty filtered list is told apart from an empty category")
    func filteredEmptyIsNotAnEmptyCategory() {
        let entries = mixedLibrary()

        #expect(LibraryListContent.filtersHideEverything(
            LibraryListContent.ActiveFilters(label: "recap", language: "IT"),
            category: .meeting,
            entries: entries
        ))
        #expect(!LibraryListContent.filtersHideEverything(
            LibraryListContent.ActiveFilters(label: "recap"),
            category: .meeting,
            entries: entries
        ))
        #expect(!LibraryListContent.filtersHideEverything(
            LibraryListContent.ActiveFilters(),
            category: .meeting,
            entries: entries
        ))
        // Nothing in Dictations at all: that is the "no dictations yet" state, not a filter problem.
        #expect(!LibraryListContent.filtersHideEverything(
            LibraryListContent.ActiveFilters(label: "recap"),
            category: .dictation,
            entries: entries
        ))
    }

    @Test("each filter's empty state leads with an action that produces that kind of entry")
    func emptyActionsMatchTheFilter() {
        #expect(LibraryListContent.emptyActions(for: .dictation, features: .all).first == .startDictation)
        #expect(LibraryListContent.emptyActions(for: .meeting, features: .all).first == .recordSystemAudio)
        #expect(LibraryListContent.emptyActions(for: .transcription, features: .all).first == .openFile)
        #expect(LibraryListContent.emptyActions(for: nil, features: .all).first == .openFile)
    }

    @Test("empty-state actions drop the ones their feature is gated off")
    func emptyActionsRespectFeatures() {
        let noCapture = FeatureSet(enabled: [.batch])
        #expect(LibraryListContent.emptyActions(for: nil, features: noCapture) == [.openFile])
        #expect(LibraryListContent.emptyActions(for: .transcription, features: .all) == [.openFile, .recordMicrophone])
        #expect(LibraryListContent.emptyActions(for: .meeting, features: noCapture) == [.openFile])
        #expect(LibraryListContent.emptyActions(for: .dictation, features: noCapture) == [.openFile])
    }

    @Test("the totals caption hides for an empty library and pluralizes otherwise")
    func totalsLabelPluralizes() {
        let english = Locale(identifier: "en_US")
        #expect(LibraryListContent.totalsLabel(for: 0, locale: english) == nil)
        #expect(LibraryListContent.totalsLabel(for: 1, locale: english) == "1 transcript")
        #expect(LibraryListContent.totalsLabel(for: 3, locale: english) == "3 transcripts")
    }
}
