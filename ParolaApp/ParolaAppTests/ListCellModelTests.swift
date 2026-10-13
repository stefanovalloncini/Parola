import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// AppKit can ask a List for a cell after SwiftUI tore the List's graph down; that cell's environment holds no model.
@MainActor
@Suite("List cells without a model")
struct ListCellModelTests {
    private let display: LibraryRowDisplay = {
        var manifest = ParolaDocument.Manifest(
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            originalAudioName: "take.m4a",
            title: "Standup",
            modelName: "stub",
            language: "it",
            labels: ["Work"],
            durationSeconds: 4_320
        )
        manifest.deletedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let entry = LibraryEntry(id: "cell", bundleURL: URL(fileURLWithPath: "/tmp/ListCellModelTests/cell.parola"), manifest: manifest)
        return LibraryRowDisplay(entry: entry, excerpt: "We agreed to ship on Friday.", usualLanguage: "EN")
    }()

    /// Drawn and read the way a late cell is: no `.environment(model)` anywhere above it.
    private func renders(_ view: some View) -> Bool {
        let hosted = HostedWindow(view.frame(width: 900), width: 900, height: 400)
        defer { hosted.close() }
        return !HostedAccessibility.elements(in: hosted.host).isEmpty
    }

    /// Whether the button opens its popover can't be read back from a hosted view, so the wiring is pinned in the source.
    @Test("the intake settings button is disabled with no model, so its popover can't trap")
    func settingsButtonDisabledWithNoModel() throws {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/ListCellModelTests.swift",
            with: "ParolaApp/Views/Library/IntakeSettings.swift"
        )
        let source = try String(contentsOfFile: path, encoding: .utf8)
        #expect(source.contains(".disabled(model == nil)"))
    }

    @Test("an entry row, a search row and a trashed row draw with no model")
    func rows() {
        #expect(renders(LibraryListRow(row: display, detail: .excerpt, isSelected: false, rename: { _ in }, delete: { _ in })))
        #expect(renders(LibraryListRow(row: display, detail: .match(showsTimestamp: true), isSelected: true, rename: { _ in }, delete: { _ in })))
        #expect(renders(EntryRow(display: display, detail: .snippet(AttributedString("ship"), timecode: "01:02", reservesTimecode: true))))
        #expect(renders(RecentlyDeletedRow(display: display, daysLeft: 3, timeLeft: "3 days", onRestore: {}, onPurge: {})))
    }

    @Test("the page's top row draws with no model: header, chips, bulk actions, intake settings and failure banner")
    func pageTop() {
        let filters = LibraryFilterBar(
            labelFilter: .constant("Work"),
            languageFilter: .constant("it"),
            dateRangeFilter: .constant(.month),
            personFilter: .constant(UUID()),
            labelOptions: ["Work"],
            languageOptions: ["en", "it"],
            peopleOptions: []
        )
        let header = LibraryPageHeader(
            title: "Library",
            subtitle: "14 transcripts · 7 h 25 min",
            subtitleHelp: nil,
            filters: filters,
            showsListControls: true,
            showsIntakeSettings: true,
            selection: .constant(["a", "b"]),
            pendingBulkDelete: .constant(false)
        )
        #expect(renders(header))
        #expect(renders(LibraryBulkActions(selection: .constant(["a", "b"]), pendingBulkDelete: .constant(false))))
        #expect(renders(IntakeSettingsButton()))
        #expect(renders(VStack { LibraryFailureBanner(); ErrorBanner(message: "The file couldn't be decoded.") }))
    }
}
