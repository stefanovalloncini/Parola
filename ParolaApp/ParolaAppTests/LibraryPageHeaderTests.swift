import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Library page header")
struct LibraryPageHeaderTests {
    @Test("the title names the place the list shows")
    func titles() {
        #expect(LibraryPageHeader.title(category: nil, personName: nil) == "Library")
        #expect(LibraryPageHeader.title(category: .meeting, personName: nil) == "Meetings")
        #expect(LibraryPageHeader.title(category: nil, personName: "Giulia Rossi") == "Giulia Rossi")
    }

    @Test("the chips fold into More only when the row laid out unfolded is wider than the header, at any window width")
    func foldsWhenTheyWouldNotFit() {
        #expect(LibraryPageHeader.foldsFilters(unfoldedRowWidth: 900, rowWidth: 892))
        #expect(!LibraryPageHeader.foldsFilters(unfoldedRowWidth: 880, rowWidth: 892))
        #expect(!LibraryPageHeader.foldsFilters(unfoldedRowWidth: 400, rowWidth: 632), "a narrow window with room keeps them out")
        #expect(!LibraryPageHeader.foldsFilters(unfoldedRowWidth: 0, rowWidth: 0), "nothing measured yet")
    }

    @Test("Export and Delete wait for a selection of more than one row")
    func bulkActionsNeedSeveralRows() {
        #expect(!LibraryBulkActions.isShown(forSelectionCount: 0))
        #expect(!LibraryBulkActions.isShown(forSelectionCount: 1), "a click selects a row; the row's own menu covers one")
        #expect(LibraryBulkActions.isShown(forSelectionCount: 2))
    }

    @Test("the subtitle counts the page's transcripts and how long they run")
    func subtitle() {
        #expect(LibraryPageHeader.subtitle(count: 14, totalSeconds: 7 * 3600 + 25 * 60) == "14 transcripts · 7 h 25 min")
        #expect(LibraryPageHeader.subtitle(count: 1, totalSeconds: 0) == "1 transcript")
        #expect(LibraryPageHeader.subtitle(count: 0, totalSeconds: 0) == "No transcripts yet")
        #expect(LibraryPageHeader.subtitle(count: 0, totalSeconds: 0, filteredOut: true) == "", "No Matches below says it")
        #expect(LibraryPageHeader.subtitle(count: 0, totalSeconds: 0, loaded: false) == "", "the first scan hasn't landed")
    }

    @Test("the subtitle reads naturally in Italian")
    func italianSubtitle() throws {
        let italian = try italianBundle()
        #expect(LibraryPageHeader.subtitle(count: 0, totalSeconds: 0, bundle: italian) == "Ancora nessuna trascrizione")
        #expect(LibraryPageHeader.subtitle(count: 2, totalSeconds: 90, bundle: italian) == "2 trascrizioni · 1 min")
    }

    @Test("a long value is cut short so one filter can't crowd the others out")
    func longFilterValues() {
        let long = String(repeating: "Quarterly planning ", count: 4)
        #expect(LibraryFilterBar.capped(long).hasPrefix("Quarterly planning"))
        #expect(LibraryFilterBar.capped(long).hasSuffix("…"))
        #expect(LibraryFilterBar.capped(long).count == LibraryFilterBar.valueCharacterCap)
        #expect(LibraryFilterBar.capped("Work") == "Work")
    }

    private let giulia = UUID()

    private func entry(
        _ id: String,
        category: EntryCategory = .transcription,
        seconds: Double? = nil,
        labels: [String] = [],
        person: UUID? = nil
    ) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            originalAudioName: "\(id).m4a",
            title: id,
            modelName: "stub",
            language: "en",
            category: category,
            labels: labels,
            durationSeconds: seconds,
            speakerAssignments: person.map { ["Speaker 1": $0] } ?? [:]
        )
        return LibraryEntry(id: id, bundleURL: URL(fileURLWithPath: "/tmp/LibraryPageHeaderTests/\(id).parola"), manifest: manifest)
    }

    @Test("the subtitle counts the transcripts the filters leave on screen")
    func subtitleCountsShownRows() {
        let entries = [
            entry("a", seconds: 60, labels: ["Work"]),
            entry("b", category: .meeting, seconds: 1800, person: giulia),
            entry("c", category: .meeting, seconds: 3540, person: giulia),
            entry("d", category: .meeting, seconds: 600),
            entry("e", seconds: 30, person: giulia),
        ]
        let sizes: [String: Int64] = ["a": 1_000, "b": 20_000, "c": 5_000, "d": 7_000]
        let shown = LibraryListContent.rows(
            from: entries, category: .meeting, labelFilter: nil, languageFilter: nil, dateRange: .all, personFilter: giulia
        )

        let totals = LibraryListContent.totals(of: shown, sizes: sizes)
        #expect(totals == .init(count: 2, seconds: 5340, bytes: 25_000))
        #expect(LibraryPageHeader.subtitle(count: totals.count, totalSeconds: totals.seconds) == "2 transcripts · 1 h 29 min")
    }

    @Test("a person with no transcripts keeps No transcripts yet; filters that empty a page with some leave the line blank")
    func emptyPersonPageSubtitle() {
        let entries = [
            entry("a", seconds: 60, labels: ["Work"]),
            entry("b", category: .meeting, seconds: 1800, person: giulia),
        ]
        let nobody = UUID()
        func subtitle(category: EntryCategory?, label: String?, person: UUID?) -> String {
            let shown = LibraryListContent.rows(
                from: entries, category: category, labelFilter: label, languageFilter: nil, dateRange: .all, personFilter: person
            )
            let filters = LibraryListContent.ActiveFilters(label: label, person: person)
            let kind = LibraryEmptyState.kind(
                entryCount: LibraryEmptyState.entryCount(in: entries, category: category),
                visibleCount: shown.count,
                filtersActive: !filters.isEmpty
            )
            let pageCount = LibraryListContent.pageCount(of: entries, category: category, person: person)
            let totals = LibraryListContent.totals(of: shown, sizes: [:])
            return LibraryPageHeader.subtitle(
                count: totals.count,
                totalSeconds: totals.seconds,
                filteredOut: LibraryEmptyState.filtersEmptied(kind, pageCount: pageCount)
            )
        }
        #expect(subtitle(category: nil, label: nil, person: nobody) == "No transcripts yet")
        #expect(subtitle(category: nil, label: "Missing", person: nil) == "")
        #expect(subtitle(category: .meeting, label: nil, person: giulia) == "1 transcript · 30 min")
    }

    @Test("the chips stay while the page holds something before its filters, a person's own page included")
    func pageCountIgnoresTheFilters() {
        let entries = [
            entry("a", seconds: 60, labels: ["Work"]),
            entry("b", category: .meeting, seconds: 1800, person: giulia),
            entry("c", category: .meeting, seconds: 600),
            entry("d", seconds: 30, person: giulia),
        ]
        #expect(LibraryListContent.pageCount(of: entries, category: nil, person: nil) == 4)
        #expect(LibraryListContent.pageCount(of: entries, category: .meeting, person: giulia) == 2, "the People chip narrows the Meetings page; it doesn't make it a new one")
        #expect(LibraryListContent.pageCount(of: entries, category: nil, person: giulia) == 2, "with no category, the person is the page")
        #expect(LibraryListContent.pageCount(of: entries, category: .dictation, person: nil) == 0)
    }

    // MARK: - Layout

    private func italianBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    private static let english = Locale(identifier: "en_US")
    private static let italian = Locale(identifier: "it_IT")

    @MainActor
    private struct HostedHeader {
        let host: NSHostingView<AnyView>
        let window: NSWindow

        func close() {
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    /// The header as the page hosts it at one window width: every filter on, with a label of an everyday length.
    private func hostedHeader(
        windowWidth: CGFloat,
        selection: Set<LibraryEntry.ID> = [],
        filtering: Bool = true,
        dimensions: Bool = true,
        showsListControls: Bool = true,
        locale: Locale = english,
        subtitle: String = LibraryPageHeader.subtitle(count: 14, totalSeconds: 7 * 3600 + 25 * 60)
    ) -> HostedHeader {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("pageheader"))
        let giulia = Person(name: "Giulia Rossi")
        let header = LibraryPageHeader(
            title: "Library",
            subtitle: subtitle,
            subtitleHelp: nil,
            filters: LibraryFilterBar(
                labelFilter: .constant(filtering ? "Quarterly planning" : nil),
                languageFilter: .constant(filtering ? "it" : nil),
                dateRangeFilter: .constant(filtering ? .month : .all),
                personFilter: .constant(filtering ? giulia.id : nil),
                labelOptions: dimensions ? ["Quarterly planning", "Research"] : [],
                languageOptions: dimensions ? ["en", "it"] : [],
                peopleOptions: dimensions ? [giulia] : []
            ),
            showsListControls: showsListControls,
            selection: selection,
            pendingBulkDelete: .constant(false)
        )
        let pageWidth = windowWidth - MainWindowLayout.sidebarIdealWidth - 2 * DS.Spacing.large
        let host = NSHostingView(rootView: AnyView(
            header
                .environment(model)
                .environment(\.locale, locale)
                .frame(width: pageWidth)
        ))
        // In a window, so the chips' accessibility frames can be brought back to the header's own coordinates.
        let window = NSWindow(
            contentRect: NSRect(x: -12_000, y: -12_000, width: pageWidth, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        // The fold reads widths measured on the first pass, so the header is laid out a second time.
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        return HostedHeader(host: host, window: window)
    }

    /// The chips are drawn by SwiftUI, not AppKit; its accessibility nodes give each one's words and where they sit.
    private func chipLabels(in hosted: HostedHeader) -> [(text: String, frame: CGRect)] {
        func read(_ key: String, of node: NSObject) -> Any? {
            node.responds(to: NSSelectorFromString(key)) ? node.value(forKey: key) : nil
        }
        var found: [(text: String, frame: CGRect)] = []
        func walk(_ node: NSObject) {
            for child in read("accessibilityChildren", of: node) as? [NSObject] ?? [] {
                let words = (read("accessibilityValue", of: child) as? String) ?? (read("accessibilityLabel", of: child) as? String)
                if let words, !words.isEmpty, let screen = (read("accessibilityFrame", of: child) as? NSValue)?.rectValue {
                    found.append((words, hosted.host.convert(hosted.window.convertFromScreen(screen), from: nil)))
                }
                walk(child)
            }
        }
        walk(hosted.host)
        return found.sorted { $0.frame.minX < $1.frame.minX }
    }

    private func chipTitles(in hosted: HostedHeader) -> [String] {
        chipLabels(in: hosted).map(\.text)
    }

    /// Every chip and every view AppKit keeps for one, against the page's right edge.
    private func spillsPastTheRight(_ hosted: HostedHeader) -> [String] {
        let edge = hosted.host.bounds.width + 0.5
        let labels = chipLabels(in: hosted).filter { $0.frame.maxX > edge }.map { "\($0.text) ends at \($0.frame.maxX)" }
        let views = hosted.host.subviews
            .filter { String(describing: type(of: $0)) != "KeyViewProxy" && $0.frame.maxX > edge }
            .map { "\(type(of: $0)) ends at \($0.frame.maxX)" }
        return labels + views
    }

    @Test("an idle chip names what it narrows; an active one shows only the value it keeps")
    func menuTitles() {
        let idle = hostedHeader(windowWidth: 1440, filtering: false)
        let active = hostedHeader(windowWidth: 1440)
        defer {
            idle.close()
            active.close()
        }
        let italianName = LanguageDisplay.name(for: "it") ?? "IT"

        #expect(chipTitles(in: idle) == ["Labels", "People", "Any time", "Sort", "More"], "Language waits in More")
        #expect(chipTitles(in: active) == ["Quarterly planning", "Giulia Rossi", italianName, "Last 30 days", "Sort", "More"])
    }

    @Test("Language is a chip only while it filters; More holds it once the page has two languages")
    func languagePlaces() {
        #expect(!LibraryFilterBar.showsLanguage(in: .chips, optionCount: 3, filtering: false))
        #expect(LibraryFilterBar.showsLanguage(in: .chips, optionCount: 3, filtering: true))
        #expect(LibraryFilterBar.showsLanguage(in: .language, optionCount: 2, filtering: false))
        #expect(!LibraryFilterBar.showsLanguage(in: .language, optionCount: 1, filtering: false))
        #expect(LibraryFilterBar.showsLanguage(in: .language, optionCount: 1, filtering: true), "a filter on stays so it can be cleared")
        #expect(LibraryFilterBar.showsLanguage(in: .submenus, optionCount: 2, filtering: false))
    }

    @Test("the chips read in Italian")
    func italianMenuTitles() {
        let idle = hostedHeader(windowWidth: 1440, filtering: false, locale: Self.italian)
        let active = hostedHeader(windowWidth: 1440, locale: Self.italian)
        defer {
            idle.close()
            active.close()
        }
        let italianName = LanguageDisplay.name(for: "it") ?? "IT"

        #expect(chipTitles(in: idle) == ["Etichette", "Persone", "Sempre", "Ordina", "Altro"])
        #expect(chipTitles(in: active) == ["Quarterly planning", "Giulia Rossi", italianName, "Ultimi 30 giorni", "Ordina", "Altro"])
    }

    @Test("at 920 points the filters wait in More; at 1440 each has its own chip")
    func foldedMenus() {
        let narrow = hostedHeader(windowWidth: MainWindowLayout.minimumWidth)
        let wide = hostedHeader(windowWidth: 1440)
        defer {
            narrow.close()
            wide.close()
        }
        #expect(chipTitles(in: narrow) == ["Sort", "More"])
        #expect(chipTitles(in: wide).count == 6)
    }

    @Test("a narrow window with room for its chips keeps them beside the subtitle")
    func narrowWindowWithRoom() {
        let hosted = hostedHeader(windowWidth: MainWindowLayout.minimumWidth, filtering: false, dimensions: false)
        defer { hosted.close() }
        #expect(chipTitles(in: hosted) == ["Any time", "Sort", "More"])
    }

    @Test("at 920 points every everyday chip and More sit beside the subtitle")
    func everydayChipsAtTheSmallestWindow() {
        let hosted = hostedHeader(windowWidth: MainWindowLayout.minimumWidth, filtering: false)
        defer { hosted.close() }
        #expect(chipTitles(in: hosted) == ["Labels", "People", "Any time", "Sort", "More"])
    }

    @Test("an empty page with nothing filtered shows no chips, not even More")
    func emptyPageHasNoChips() {
        let empty = hostedHeader(windowWidth: 1180, filtering: false, showsListControls: false)
        let filtered = hostedHeader(windowWidth: 1180, showsListControls: false)
        defer {
            empty.close()
            filtered.close()
        }
        #expect(chipTitles(in: empty).isEmpty)
        let italianName = LanguageDisplay.name(for: "it") ?? "IT"
        #expect(chipTitles(in: filtered) == ["Quarterly planning", "Giulia Rossi", italianName, "Last 30 days", "More"], "a filter on stays so it can be cleared")
    }

    @Test("with every filter on, the header's controls stay inside the page", arguments: [920.0, 1000, 1040, 1180, 1440])
    func controlsStayInside(windowWidth: Double) {
        let hosted = hostedHeader(windowWidth: CGFloat(windowWidth))
        defer { hosted.close() }
        let titles = chipTitles(in: hosted)
        #expect(titles.last == "More", "the chips weren't read, so nothing was measured: \(titles)")
        let spilled = spillsPastTheRight(hosted)
        #expect(spilled.isEmpty, "\(spilled)")
    }

    @Test("with every filter on and several rows selected, Export and Delete still fit", arguments: [920.0, 1000, 1180, 1440])
    func selectionFits(windowWidth: Double) {
        let hosted = hostedHeader(windowWidth: CGFloat(windowWidth), selection: ["a", "b", "c"])
        defer { hosted.close() }
        let titles = chipTitles(in: hosted)
        #expect(titles.last == "More", "the chips weren't read, so nothing was measured: \(titles)")
        let spilled = spillsPastTheRight(hosted)
        #expect(spilled.isEmpty, "\(spilled)")
    }

    @Test("the Italian chips stay inside the page too", arguments: [920.0, 1000, 1040, 1180])
    func italianStaysInside(windowWidth: Double) throws {
        let subtitle = LibraryPageHeader.subtitle(count: 14, totalSeconds: 7 * 3600 + 25 * 60, bundle: try italianBundle())
        let hosted = hostedHeader(windowWidth: CGFloat(windowWidth), locale: Self.italian, subtitle: subtitle)
        defer { hosted.close() }
        let titles = chipTitles(in: hosted)
        #expect(titles.last == "Altro", "the chips weren't read, so nothing was measured: \(titles)")
        let spilled = spillsPastTheRight(hosted)
        #expect(spilled.isEmpty, "\(spilled)")
    }

    @Test("with every filter on and rows selected, 1180 points is too narrow to keep the chips out")
    func selectionFoldsAtTheDefaultSize() {
        let hosted = hostedHeader(windowWidth: 1180, selection: ["a", "b", "c"])
        defer { hosted.close() }
        let titles = chipTitles(in: hosted)
        #expect(titles.suffix(2) == ["Sort", "More"], "\(titles)")
        #expect(!titles.contains("Quarterly planning"), "\(titles)")
    }
}
