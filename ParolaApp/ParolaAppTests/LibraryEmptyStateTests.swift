import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

private func libraryEntry(_ id: String, category: EntryCategory, labels: [String] = [], person: UUID? = nil) -> LibraryEntry {
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
            libraryEntry("standup", category: .meeting, labels: ["weekly"]),
            libraryEntry("memo", category: .transcription, person: anna),
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
            libraryEntry("a", category: .meeting, labels: ["weekly"]),
            libraryEntry("b", category: .meeting, person: UUID()),
            libraryEntry("c", category: .transcription),
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
}

@MainActor
@Suite("The hero on screen")
struct EmptyLibraryHeroRenderTests {
    /// SwiftUI draws the hero's own buttons itself; its source picker is an AppKit control, so it stands in for the hero.
    private func heroPicker(in window: NSWindow) -> NSSegmentedControl? {
        window.contentView?.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl, control.segmentCount == 2,
               control.label(forSegment: 0) == "Microphone", control.label(forSegment: 1) == "System Audio" {
                return control
            }
            return view.subviews.lazy.compactMap(find).first
        }
        return window.contentView.flatMap(find)
    }

    @Test("an empty library's Library page shows the hero; a person, a category or a first entry takes it away")
    func heroOnThePage() async {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("hero-page"))
        await model.libraryRefreshTask?.value
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window)
        window.contentViewController = NSHostingController(rootView: ContentView().environment(model))
        defer { withExtendedLifetime(controller) { window.close() } }

        let onLibraryPage = await waitUntil { heroPicker(in: window) != nil }
        #expect(onLibraryPage, "the empty Library page shows the hero")

        model.personFilter = UUID()
        let offPersonPage = await waitUntil { heroPicker(in: window) == nil }
        #expect(offPersonPage, "a person's page over an empty library keeps its own state")
        model.personFilter = nil
        let backFromPerson = await waitUntil { heroPicker(in: window) != nil }
        #expect(backFromPerson)

        model.libraryFilter = .meeting
        let offCategoryPage = await waitUntil { heroPicker(in: window) == nil }
        #expect(offCategoryPage, "a category's page over an empty library keeps its own state")
        model.libraryFilter = nil
        let backFromCategory = await waitUntil { heroPicker(in: window) != nil }
        #expect(backFromCategory)

        model.libraryEntries = [libraryEntry("first", category: .transcription)]
        let offWithAnEntry = await waitUntil { heroPicker(in: window) == nil }
        #expect(offWithAnEntry, "the first entry puts the list in its place")
    }

    /// The strongly red, opaque pixels a render holds, and the box around them.
    private func recordRed(in view: some View) throws -> (count: Int, box: CGRect) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        var count = 0
        var box = CGRect.null
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.9, color.redComponent > 0.6,
                      color.greenComponent < 0.35, color.blueComponent < 0.35 else { continue }
                count += 1
                box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return (count, box)
    }

    @Test("the circle draws its 28 pt recording-red dot, faded while no take can start")
    func recordDot() throws {
        let model = AppModel(bootstrap: AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("hero-dot"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: SystemFilePicker(),
            enabledFeaturesOverride: [.micRecording]
        ))
        let ready = try recordRed(in: EmptyLibraryHero().environment(model))
        #expect(ready.count > 400)
        #expect(abs(ready.box.width - 28) <= 2 && abs(ready.box.height - 28) <= 2, "the red is the dot alone: \(ready.box)")

        model.quitPending = true
        let refused = try recordRed(in: EmptyLibraryHero().environment(model))
        #expect(refused.count == 0, "a circle that can't start a take fades")
    }
}
