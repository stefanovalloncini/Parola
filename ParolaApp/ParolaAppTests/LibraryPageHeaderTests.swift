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
    }

    @Test("the subtitle counts the page's transcripts and how long they run")
    func subtitle() {
        #expect(LibraryPageHeader.subtitle(count: 14, totalSeconds: 7 * 3600 + 25 * 60) == "14 transcripts · 7 h 25 min")
        #expect(LibraryPageHeader.subtitle(count: 1, totalSeconds: 0) == "1 transcript")
        #expect(LibraryPageHeader.subtitle(count: 0, totalSeconds: 0) == "No transcripts yet")
    }

    @Test("the subtitle reads naturally in Italian")
    func italianSubtitle() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        #expect(LibraryPageHeader.subtitle(count: 0, totalSeconds: 0, bundle: italian) == "Ancora nessuna trascrizione")
        #expect(LibraryPageHeader.subtitle(count: 2, totalSeconds: 90, bundle: italian) == "2 trascrizioni · 1 min")
    }

    @Test("an active filter names what it keeps; an idle one names the menu")
    func filterTitles() {
        #expect(LibraryFilterBar.labelsTitle(nil) == "Labels")
        #expect(LibraryFilterBar.labelsTitle("Work") == "Labels: Work")
        #expect(LibraryFilterBar.peopleTitle(nil) == "People")
        #expect(LibraryFilterBar.peopleTitle("Giulia Rossi") == "People: Giulia Rossi")
        #expect(LibraryFilterBar.languageTitle(nil) == "Language")
        #expect(LibraryFilterBar.languageTitle("Italian") == "Language: Italian")
    }

    @Test("the filter menus read in Italian")
    func italianFilterTitles() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        #expect(LibraryFilterBar.labelsTitle("Lavoro", bundle: italian) == "Etichette: Lavoro")
        #expect(LibraryFilterBar.peopleTitle("Giulia", bundle: italian) == "Persone: Giulia")
        #expect(LibraryFilterBar.languageTitle("Inglese", bundle: italian) == "Lingua: Inglese")
        #expect(LibraryFilterBar.labelsTitle(nil, bundle: italian) == "Etichette")
    }

    @Test("a long label is cut short so one filter can't push the others off the header")
    func longFilterValues() {
        let long = String(repeating: "Quarterly planning ", count: 4)
        let title = LibraryFilterBar.labelsTitle(long)
        #expect(title.hasPrefix("Labels: Quarterly planning"))
        #expect(title.hasSuffix("…"))
        #expect(title.count < long.count)
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

    /// Every filter on, with long values: the widest the header's controls get.
    private func hostedHeader(windowWidth: CGFloat, selection: Set<LibraryEntry.ID>) -> NSHostingView<AnyView> {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("pageheader"))
        let giulia = Person(name: "Giulia Rossi")
        let header = LibraryPageHeader(
            title: "Library",
            subtitle: LibraryPageHeader.subtitle(count: 14, totalSeconds: 7 * 3600 + 25 * 60),
            subtitleHelp: nil,
            filters: LibraryFilterBar(
                labelFilter: .constant("Quarterly planning"),
                languageFilter: .constant("it"),
                dateRangeFilter: .constant(.month),
                personFilter: .constant(giulia.id),
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
            header.environment(model).environment(\.mainWindowWidth, windowWidth).frame(width: pageWidth)
        ))
        host.frame = NSRect(x: 0, y: 0, width: pageWidth, height: 120)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func popUps(in view: NSView) -> [NSPopUpButton] {
        view.subviews.flatMap { sub -> [NSPopUpButton] in
            (sub as? NSPopUpButton).map { [$0] } ?? popUps(in: sub)
        }
    }

    /// The text menus are AppKit pop-ups; More, drawn in SwiftUI, follows the last of them.
    private func spillsPastTheRight(_ host: NSView) -> [String] {
        let moreRoom = DS.Spacing.regular + GlyphButtonStyle.defaultSide
        return popUps(in: host).compactMap { button in
            let frame = button.convert(button.bounds, to: host)
            return frame.maxX + moreRoom > host.bounds.width + 0.5 ? "\(button.title) ends at \(frame.maxX)" : nil
        }
    }

    @Test("at 920 points the filters wait in More; at 1180 each has its own menu")
    func foldedMenus() {
        let narrow = hostedHeader(windowWidth: MainWindowLayout.minimumWidth, selection: [])
        let wide = hostedHeader(windowWidth: 1180, selection: [])
        let italian = LanguageDisplay.name(for: "it") ?? "IT"

        #expect(popUps(in: narrow).map(\.title) == ["Sort"])
        #expect(popUps(in: wide).map(\.title) == [
            "Labels: Quarterly planning", "People: Giulia Rossi", "Language: \(italian)", "Last 30 days", "Sort",
        ])
    }

    @Test("with every filter on, the header's controls stay inside the page", arguments: [920.0, 1180.0])
    func controlsStayInside(windowWidth: Double) {
        let host = hostedHeader(windowWidth: CGFloat(windowWidth), selection: [])
        #expect(spillsPastTheRight(host).isEmpty, "\(spillsPastTheRight(host))")
    }

    @Test("a selection's Export and Delete still fit beside the folded menus")
    func selectionFitsWhenFolded() {
        let host = hostedHeader(windowWidth: MainWindowLayout.minimumWidth, selection: ["a", "b", "c"])
        #expect(spillsPastTheRight(host).isEmpty, "\(spillsPastTheRight(host))")
    }
}
