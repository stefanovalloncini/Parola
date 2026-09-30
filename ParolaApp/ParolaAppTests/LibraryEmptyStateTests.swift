import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@Suite("Library empty states")
struct LibraryEmptyStateTests {
    @Test("an empty library shows the hero; filters that match nothing offer Clear Filters")
    func kinds() {
        #expect(LibraryEmptyState.kind(entryCount: 0, visibleCount: 0, filtersActive: false) == .emptyLibrary)
        #expect(LibraryEmptyState.kind(entryCount: 12, visibleCount: 0, filtersActive: true) == .noMatches)
        #expect(LibraryEmptyState.kind(entryCount: 12, visibleCount: 3, filtersActive: true) == .none)
        #expect(LibraryEmptyState.kind(entryCount: 0, visibleCount: 0, filtersActive: true) == .emptyLibrary)
    }

    @Test("Clear Filters is offered only while a filter is on to clear")
    func noMatchesNeedsAFilter() {
        #expect(LibraryEmptyState.kind(entryCount: 12, visibleCount: 0, filtersActive: false) == .none)
        #expect(LibraryEmptyState.kind(entryCount: 12, visibleCount: 12, filtersActive: false) == .none)
    }

    private func entry(_ id: String, category: EntryCategory, labels: [String] = [], person: UUID? = nil) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            originalAudioName: "\(id).m4a",
            title: id,
            modelName: "stub",
            language: "en",
            category: category,
            labels: labels,
            speakerAssignments: person.map { ["Speaker 1": $0] } ?? [:]
        )
        return LibraryEntry(id: id, bundleURL: URL(fileURLWithPath: "/tmp/LibraryEmptyStateTests/\(id).parola"), manifest: manifest)
    }

    private func kind(
        of entries: [LibraryEntry],
        category: EntryCategory?,
        filters: LibraryListContent.ActiveFilters
    ) -> LibraryEmptyState.Kind {
        let visible = LibraryListContent.rows(
            from: entries, category: category, labelFilter: filters.label, languageFilter: filters.language,
            dateRange: filters.dateRange, personFilter: filters.person
        )
        return LibraryEmptyState.kind(
            entryCount: LibraryEmptyState.entryCount(in: entries, category: category),
            visibleCount: visible.count,
            filtersActive: !filters.isEmpty
        )
    }

    @Test("a page the filters emptied is told apart from a page with nothing on it")
    func filteredPageIsNotAnEmptyPage() {
        let anna = UUID()
        let library = [
            entry("standup", category: .meeting, labels: ["weekly"]),
            entry("memo", category: .transcription, person: anna),
        ]

        #expect(kind(of: library, category: .meeting, filters: .init(label: "recap")) == .noMatches)
        #expect(kind(of: library, category: .meeting, filters: .init(label: "weekly")) == .none)
        // Nothing in Dictations at all: that is the page's own empty state, not a filter problem.
        #expect(kind(of: library, category: .dictation, filters: .init(label: "recap")) == .emptyLibrary)
        #expect(kind(of: library, category: nil, filters: .init(person: UUID())) == .noMatches, "a person with nothing is a filter to clear")
        #expect(kind(of: library, category: nil, filters: .init(person: anna)) == .none)
        #expect(kind(of: [], category: nil, filters: .init(person: anna)) == .emptyLibrary)
        #expect(kind(of: [], category: nil, filters: .init()) == .emptyLibrary)
    }

    @Test("the page's count is its category's, before any filter or person")
    func entryCountIgnoresFilters() {
        let library = [
            entry("a", category: .meeting, labels: ["weekly"]),
            entry("b", category: .meeting, person: UUID()),
            entry("c", category: .transcription),
        ]
        #expect(LibraryEmptyState.entryCount(in: library, category: nil) == 3)
        #expect(LibraryEmptyState.entryCount(in: library, category: .meeting) == 2)
        #expect(LibraryEmptyState.entryCount(in: library, category: .dictation) == 0)
    }

    @Test("the hero is the Library page's alone: a category or a person over an empty library keeps its own state")
    func heroOnlyOnTheLibraryPage() {
        #expect(LibraryEmptyState.showsHero(.emptyLibrary, category: nil, person: nil))
        #expect(!LibraryEmptyState.showsHero(.emptyLibrary, category: nil, person: UUID()))
        #expect(!LibraryEmptyState.showsHero(.emptyLibrary, category: .meeting, person: nil))
        #expect(!LibraryEmptyState.showsHero(.noMatches, category: nil, person: nil))
        #expect(!LibraryEmptyState.showsHero(.none, category: nil, person: nil))
    }
}

@MainActor
@Suite("Empty library hero")
struct EmptyLibraryHeroTests {
    private let everything = FeatureSet.all
    private let micOnly = FeatureSet(enabled: [.micRecording])
    private let systemAudioOnly = FeatureSet(enabled: [.meetings])
    private let noCapture = FeatureSet(enabled: [.youtube, .batch])

    @Test("the circle records the source picked while both are on, else the one the build allows")
    func source() {
        #expect(EmptyLibraryHero.source(remembered: .systemAudio, features: everything) == .systemAudio)
        #expect(EmptyLibraryHero.source(remembered: .microphone, features: everything) == .microphone)
        #expect(EmptyLibraryHero.source(remembered: .systemAudio, features: micOnly) == .microphone)
        #expect(EmptyLibraryHero.source(remembered: .microphone, features: systemAudioOnly) == .systemAudio)
        #expect(EmptyLibraryHero.source(remembered: .microphone, features: noCapture) == nil)
    }

    @Test("Microphone | System Audio shows only when both can record")
    func sourceChoice() {
        #expect(EmptyLibraryHero.offersSourceChoice(features: everything))
        #expect(!EmptyLibraryHero.offersSourceChoice(features: micOnly))
        #expect(!EmptyLibraryHero.offersSourceChoice(features: systemAudioOnly))
        #expect(!EmptyLibraryHero.offersSourceChoice(features: noCapture))
    }

    @Test("the hint under Record is the File menu's shortcut for that source")
    func shortcutHint() {
        #expect(EmptyLibraryHero.shortcutHint(for: .microphone) == "⌘N")
        #expect(EmptyLibraryHero.shortcutHint(for: .systemAudio) == "⌥⌘N")
    }

    @Test("the drop line leads with 'or' only under a record control")
    func dropPrompt() {
        #expect(EmptyLibraryHero.dropPrompt(offersRecording: true) == "or drop audio and video anywhere")
        #expect(EmptyLibraryHero.dropPrompt(offersRecording: false) == "Drop audio and video anywhere")
    }

    @Test("the hero reads in Italian")
    func italian() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        #expect(EmptyLibraryHero.dropPrompt(offersRecording: true, bundle: italian) == "oppure trascina audio e video ovunque")
        #expect(EmptyLibraryHero.dropPrompt(offersRecording: false, bundle: italian) == "Trascina audio e video ovunque")
        #expect(String(localized: "Paste a link", bundle: italian) == "Incolla un link")
        #expect(String(localized: "Recording source", bundle: italian) == "Sorgente di registrazione")
    }

    @Test("the source starts on the microphone and is remembered across launches")
    func sourceIsRemembered() async {
        let defaults = temporaryDefaults()
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("hero-source"))
        await model.libraryRefreshTask?.value
        #expect(model.lastRecordSource == .microphone)

        model.lastRecordSource = .systemAudio
        let relaunched = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("hero-source-2"))
        await relaunched.libraryRefreshTask?.value
        #expect(relaunched.lastRecordSource == .systemAudio)
        #expect(UnscopedSettingsKeys.all.contains("lastRecordSource"), "a backup keeps it and a full reset clears it")
    }

    private func source(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/LibraryEmptyStateTests.swift",
            with: "ParolaApp/\(name).swift"
        )
        return try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("the circle starts the source it shows, and Paste a link opens the link sheet the way ⌘V does")
    func heroWiring() throws {
        let hero = try source("Views/Library/EmptyLibraryHero")
        #expect(hero.contains("model.startRecording(source: source)"))
        #expect(hero.contains(".disabled(!model.canStartTake(source))"))
        #expect(hero.contains("Button(\"Paste a link\") { model.openLinkSheet(prefill: nil) }"))
    }
}
