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

    @Test("below 1000 points the filter menus fold into More")
    func folding() {
        #expect(LibraryPageHeader.foldsFilters(windowWidth: 920))
        #expect(!LibraryPageHeader.foldsFilters(windowWidth: 1180))
        #expect(!LibraryPageHeader.foldsFilters(windowWidth: 0), "a window not measured yet keeps them unfolded")
    }

    @Test("wider than 1000 points they still fold when the row laid out unfolded is wider than the header")
    func foldsWhenTheyWouldNotFit() {
        #expect(LibraryPageHeader.foldsFilters(windowWidth: 1180, unfoldedRowWidth: 900, rowWidth: 892))
        #expect(!LibraryPageHeader.foldsFilters(windowWidth: 1180, unfoldedRowWidth: 880, rowWidth: 892))
        #expect(LibraryPageHeader.foldsFilters(windowWidth: 920, unfoldedRowWidth: 400, rowWidth: 632))
        #expect(!LibraryPageHeader.foldsFilters(windowWidth: 0, unfoldedRowWidth: 0, rowWidth: 0), "nothing measured yet")
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

    @Test("the subtitle counts the page before any filter narrows it")
    func pageTotalsIgnoreTheFilters() {
        let entries = [
            entry("a", seconds: 60, labels: ["Work"]),
            entry("b", category: .meeting, seconds: 1800, person: giulia),
            entry("c", category: .meeting, seconds: 600),
            entry("d", seconds: 30, person: giulia),
        ]
        let sizes: [String: Int64] = ["a": 1_000, "b": 20_000, "c": 5_000]

        let library = LibraryListContent.pageTotals(of: entries, category: nil, person: nil, sizes: sizes)
        #expect(library == .init(count: 4, seconds: 2490, bytes: 26_000))

        let meetings = LibraryListContent.pageTotals(of: entries, category: .meeting, person: giulia, sizes: sizes)
        #expect(meetings == .init(count: 2, seconds: 2400, bytes: 25_000), "the People menu narrows the Meetings page; it doesn't make it a new one")

        let person = LibraryListContent.pageTotals(of: entries, category: nil, person: giulia, sizes: sizes)
        #expect(person == .init(count: 2, seconds: 1830, bytes: 20_000), "with no category, the person is the page")
    }

    // MARK: - Layout

    private func italianBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    private static let english = Locale(identifier: "en_US")
    private static let italian = Locale(identifier: "it_IT")

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
                labelOptions: ["Quarterly planning", "Research"],
                languageOptions: ["en", "it"],
                peopleOptions: [giulia]
            ),
            showsListControls: true,
            selection: selection,
            pendingBulkDelete: .constant(false)
        )
        let pageWidth = windowWidth - MainWindowLayout.sidebarIdealWidth - 2 * DS.Spacing.large
        let host = NSHostingView(rootView: AnyView(
            header
                .environment(model)
                .environment(\.mainWindowWidth, windowWidth)
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

        #expect(chipTitles(in: idle) == ["Labels", "People", "Language", "Any time", "Sort", "More"])
        #expect(chipTitles(in: active) == ["Quarterly planning", "Giulia Rossi", italianName, "Last 30 days", "Sort", "More"])
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

        #expect(chipTitles(in: idle) == ["Etichette", "Persone", "Lingua", "Sempre", "Ordina", "Altro"])
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

    @Test("with every filter on, the header's controls stay inside the page", arguments: [920.0, 1000, 1040, 1180, 1440])
    func controlsStayInside(windowWidth: Double) {
        let hosted = hostedHeader(windowWidth: CGFloat(windowWidth))
        defer { hosted.close() }
        let spilled = spillsPastTheRight(hosted)
        #expect(spilled.isEmpty, "\(spilled)")
    }

    @Test("with every filter on and several rows selected, Export and Delete still fit", arguments: [920.0, 1000, 1180, 1440])
    func selectionFits(windowWidth: Double) {
        let hosted = hostedHeader(windowWidth: CGFloat(windowWidth), selection: ["a", "b", "c"])
        defer { hosted.close() }
        let spilled = spillsPastTheRight(hosted)
        #expect(spilled.isEmpty, "\(spilled)")
    }

    @Test("the Italian chips stay inside the page too", arguments: [1000.0, 1040, 1180])
    func italianStaysInside(windowWidth: Double) throws {
        let subtitle = LibraryPageHeader.subtitle(count: 14, totalSeconds: 7 * 3600 + 25 * 60, bundle: try italianBundle())
        let hosted = hostedHeader(windowWidth: CGFloat(windowWidth), locale: Self.italian, subtitle: subtitle)
        defer { hosted.close() }
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
