import AppKit
import Foundation
import SwiftUI
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

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
        language: String = "en",
        durationSeconds: Double? = nil
    ) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(
            createdAt: Self.baseDate.addingTimeInterval(offset),
            originalAudioName: "\(title).m4a",
            title: title,
            modelName: "stub",
            language: language,
            category: category,
            labels: labels,
            pinned: pinned,
            durationSeconds: durationSeconds
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

    /// Library rows are laid out in the sidebar, not the transcript pane; the width is this suite's own.
    private static let measuredRowWidth: CGFloat = 520

    private func rowHeight(
        density: String,
        style: EntryRowStyle,
        excerpt: String? = nil,
        labels: [String] = []
    ) async -> CGFloat {
        let model = await makeModel()
        model.sidebarDensity = density
        let display = LibraryRowDisplay(
            entry: entry(id: "a", title: "Alpha", offset: 0, labels: labels),
            excerpt: excerpt
        )
        let host = NSHostingView(
            rootView: EntryRow(display: display, style: style, detail: .excerpt(excerpt))
                .environment(model)
                .frame(width: Self.measuredRowWidth)
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// The home style carries the same content without the declared height, so it measures what the library row
    /// is pinned to. Comparing the two is what can fail: asserting the library row's own constant cannot.
    @Test("the declared library row height is the height the row would have measured")
    func rowHeightMatchesMeasuredContent() async {
        let excerpt = String(repeating: "parola ", count: 60)
        let comfortable = await rowHeight(density: "comfortable", style: .home, excerpt: excerpt)
        let compact = await rowHeight(density: "compact", style: .home, excerpt: excerpt)
        let titleOnly = await rowHeight(density: "comfortable", style: .home)
        let compactTitleOnly = await rowHeight(density: "compact", style: .home)

        #expect(comfortable == EntryRowMetrics.detail)
        #expect(compact == EntryRowMetrics.compactDetail)
        #expect(titleOnly == EntryRowMetrics.titleOnly)
        #expect(compactTitleOnly == EntryRowMetrics.compactTitleOnly)
        #expect(await rowHeight(density: "comfortable", style: .list, excerpt: excerpt) == comfortable)
        #expect(await rowHeight(density: "compact", style: .list, excerpt: excerpt) == compact)
        #expect(await rowHeight(density: "comfortable", style: .list) == titleOnly)
    }

    /// A chip taller than the title line would pay for itself with the excerpt's second line.
    @Test("label chips leave the excerpt the same room as a row without them")
    func labelChipsDoNotShortenTheExcerpt() async {
        let excerpt = String(repeating: "parola ", count: 60)
        let plain = await rowHeight(density: "comfortable", style: .home, excerpt: excerpt)
        let labelled = await rowHeight(
            density: "comfortable",
            style: .home,
            excerpt: excerpt,
            labels: ["draft", "shared", "q4"]
        )

        #expect(labelled == plain)
        #expect(labelled == EntryRowMetrics.detail)
        #expect(await rowHeight(density: "compact", style: .home, excerpt: excerpt, labels: ["draft"])
            == EntryRowMetrics.compactDetail)
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

    @Test("the meeting and dictation empty states end on a way into their settings")
    func emptyActionsOfferTheirSettings() {
        #expect(LibraryListContent.emptyActions(for: .meeting, features: .all).last == .meetingSettings)
        #expect(LibraryListContent.emptyActions(for: .dictation, features: .all).last == .dictationSettings)
        #expect(!LibraryListContent.emptyActions(for: .transcription, features: .all).contains(.meetingSettings))
        #expect(!LibraryListContent.emptyActions(for: nil, features: .all).contains(.dictationSettings))
    }

    @Test("a gated-off feature takes its settings shortcut with it")
    func settingsShortcutsFollowTheirFeature() {
        let noMeetings = FeatureSet(enabled: [.dictation])
        #expect(!LibraryListContent.emptyActions(for: .meeting, features: noMeetings).contains(.meetingSettings))
        #expect(LibraryListContent.emptyActions(for: .dictation, features: noMeetings).contains(.dictationSettings))
    }

    @Test("the totals caption hides for an empty library and pluralizes otherwise")
    func totalsLabelPluralizes() {
        let english = Locale(identifier: "en_US")
        #expect(LibraryListContent.totalsLabel(for: 0, locale: english) == nil)
        #expect(LibraryListContent.totalsLabel(for: 1, locale: english) == "1 transcript")
        #expect(LibraryListContent.totalsLabel(for: 3, locale: english) == "3 transcripts")
    }

    @Test("the header subtitle adds how long the listed entries run, and drops it at zero")
    func listSubtitleCarriesTheSpan() {
        let english = Locale(identifier: "en_US")
        #expect(LibraryListContent.listSubtitle(count: 0, totalSeconds: 900, locale: english) == nil)
        #expect(LibraryListContent.listSubtitle(count: 1, totalSeconds: 0, locale: english) == "1 transcript")
        #expect(LibraryListContent.listSubtitle(count: 3, totalSeconds: 0.4, locale: english) == "3 transcripts")
        #expect(
            LibraryListContent.listSubtitle(count: 11, totalSeconds: 4800, locale: english)
                == "11 transcripts · 1 hr, 20 min of audio"
        )
    }

    /// The same duration means "transcribed" one page over, so the list has to say which of the two it is.
    @Test("the header subtitle says the span is audio, in Italian too")
    func listSubtitleNamesItsSpan() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let italian = Locale(identifier: "it_IT")
        #expect(
            LibraryListContent.listSubtitle(count: 2, totalSeconds: 120, bundle: bundle, locale: italian)
                == "2 trascrizioni · \(AppFormat.duration(seconds: 120, locale: italian)) di audio"
        )
    }

    /// The subtitle is one string with two locales' worth of formatting in it; both halves take the same one.
    @Test("the header subtitle formats its span in the locale it was handed")
    func listSubtitleFollowsTheLocale() {
        let italian = LibraryListContent.listSubtitle(count: 2, totalSeconds: 120, locale: Locale(identifier: "it_IT"))
        #expect(italian?.contains("min") == true)
        #expect(italian?.hasPrefix("2 ") == true)
    }

    @Test("the search caption counts the entries and the hits inside them")
    func searchTotalsLabelCountsBoth() {
        let english = Locale(identifier: "en_US")
        #expect(LibraryListContent.searchTotalsLabel(entries: 0, matches: 0, locale: english) == nil)
        #expect(LibraryListContent.searchTotalsLabel(entries: 0, matches: 4, locale: english) == nil)
        #expect(
            LibraryListContent.searchTotalsLabel(entries: 10, matches: 14, locale: english)
                == "10 transcripts · 14 matches"
        )
        #expect(
            LibraryListContent.searchTotalsLabel(entries: 1, matches: 1, locale: english)
                == "1 transcript · 1 match"
        )
    }

    /// A query edit can leave the same entries matching a different number of times; the caption has to follow.
    @Test("the search caption follows the hit counts when the entry set does not change")
    func searchCaptionFollowsTheCounts() {
        let english = Locale(identifier: "en_US")
        let ids = ["a", "b"]
        func matches(_ counts: [Int]) -> [String: LibrarySearchIndex.Match] {
            Dictionary(uniqueKeysWithValues: zip(ids, counts).map { id, count in
                (id, LibrarySearchIndex.Match(entryID: id, score: 1, matchCount: count, snippet: "s"))
            })
        }
        #expect(
            LibraryListContent.searchTotalsLabel(for: ids, matches: matches([3, 4]), locale: english)
                == "2 transcripts · 7 matches"
        )
        #expect(
            LibraryListContent.searchTotalsLabel(for: ids, matches: matches([1, 1]), locale: english)
                == "2 transcripts · 2 matches"
        )
        #expect(LibraryListContent.searchTotalsLabel(for: [], matches: matches([3, 4]), locale: english) == nil)
    }

    /// The subtitle is the header's claim about the list under it: under a filter it counts what is left.
    @Test("the header counts the rows the filter left, not the whole library")
    func subtitleCountsTheFilteredRows() {
        let english = Locale(identifier: "en_US")
        let entries = [
            entry(id: "a", title: "Alpha", offset: 100, durationSeconds: 30),
            entry(id: "b", title: "Beta", offset: 200, category: .meeting, durationSeconds: 90),
            entry(id: "c", title: "Gamma", offset: 300, category: .meeting, durationSeconds: 30),
        ]
        func subtitle(_ category: EntryCategory?) -> String? {
            let shown = LibraryListContent.rows(
                from: entries, category: category, labelFilter: nil, languageFilter: nil, dateRange: .all
            )
            return LibraryListContent.listSubtitle(
                count: shown.count,
                totalSeconds: shown.reduce(0) { $0 + ($1.durationSeconds ?? 0) },
                locale: english
            )
        }

        #expect(subtitle(nil) == "3 transcripts · 2 min, 30 sec of audio")
        #expect(subtitle(.meeting) == "2 transcripts · 2 min of audio")
        #expect(subtitle(.transcription) == "1 transcript · 30 sec of audio")
    }

    /// An index written before the counts existed answers 0, and a caption reading "· 0 matches" would be a lie.
    @Test("the search caption drops the hit count when the index has none")
    func searchTotalsLabelWithoutCounts() {
        let english = Locale(identifier: "en_US")
        #expect(LibraryListContent.searchTotalsLabel(entries: 2, matches: 0, locale: english) == "2 transcripts")
    }

    @Test("a result row shows the time of its first hit, and nothing for a title-only match")
    func searchRowTimestamp() {
        func match(_ seconds: Double?) -> LibrarySearchIndex.Match {
            LibrarySearchIndex.Match(
                entryID: "a",
                score: 1,
                snippet: "s",
                firstHit: seconds.map { .init(seconds: $0, segmentIndex: 2, textOffset: 40) }
            )
        }
        #expect(SearchResultRow.timestamp(for: match(754)) == "12:34")
        #expect(SearchResultRow.timestamp(for: match(3754)) == "1:02:34")
        #expect(SearchResultRow.timestamp(for: match(nil)) == nil)
        #expect(SearchResultRow.timestamp(for: nil) == nil)
    }

    @Test("the timestamp column is kept for a list where something was spoken, and dropped where nothing was")
    func timestampSlotFollowsTheList() {
        let ids = ["a", "b"]
        func matches(_ seconds: [Double?]) -> [String: LibrarySearchIndex.Match] {
            Dictionary(uniqueKeysWithValues: zip(ids, seconds).map { id, at in
                (id, LibrarySearchIndex.Match(
                    entryID: id,
                    score: 1,
                    snippet: "s",
                    firstHit: at.map { .init(seconds: $0, segmentIndex: 1, textOffset: 8) }
                ))
            })
        }
        #expect(LibraryListContent.showsTimestampSlot(for: ids, matches: matches([12, 30])))
        #expect(LibraryListContent.showsTimestampSlot(for: ids, matches: matches([nil, 30])))
        #expect(!LibraryListContent.showsTimestampSlot(for: ids, matches: matches([nil, nil])))
        #expect(!LibraryListContent.showsTimestampSlot(for: [], matches: matches([12, 30])))
    }

    /// The slot is reserved on every row so the snippets line up; too narrow a one would truncate the longest clock.
    @Test("the reserved timestamp slot fits the longest time a row can show")
    func timestampSlotFitsTheLongestClock() {
        let caption = NSFont.preferredFont(forTextStyle: .caption1)
        let mono = NSFont.monospacedSystemFont(ofSize: caption.pointSize, weight: .regular)
        for font in [caption, mono] {
            let width = ("1:02:34" as NSString).size(withAttributes: [.font: font]).width
            #expect(width <= EntryRowMetrics.timecodeWidth)
        }
    }

    /// However long the snippet runs, the row is one height — that is what keeps a results list from stepping.
    @Test("a search result row is the same height whatever its snippet says")
    func searchRowHoldsOneHeight() async {
        let model = await makeModel()
        let display = LibraryRowDisplay(entry: entry(id: "a", title: "Alpha", offset: 0))
        func height(_ snippet: String, at seconds: Double? = nil) -> CGFloat {
            let match = LibrarySearchIndex.Match(
                entryID: "a",
                score: 1,
                matchCount: 2,
                snippet: snippet,
                firstHit: seconds.map { .init(seconds: $0, segmentIndex: 2, textOffset: 40) }
            )
            // The width has to be on the view: `fittingSize` proposes its own, and the snippet never wraps.
            let host = NSHostingView(
                rootView: SearchResultRow(display: display, match: match)
                    .environment(model)
                    .frame(width: Self.measuredRowWidth)
            )
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let twoLines = height(String(repeating: "parola ", count: 40))
        #expect(twoLines == EntryRowMetrics.detail)
        #expect(twoLines == height(String(repeating: "parola ", count: 400)))
        #expect(height("breve") == twoLines)
        #expect(height("") == twoLines)
        #expect(height("breve", at: 754) == twoLines)
        #expect(height(String(repeating: "parola ", count: 400), at: 754) == twoLines)
    }
}
