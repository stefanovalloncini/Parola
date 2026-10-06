import AppKit
import Foundation
import SwiftUI
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Statistics page", .serialized)
struct StatisticsViewTests {
    private static let reference = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeModel(_ defaults: UserDefaults, entries: [LibraryEntry]) -> AppModel {
        let model = AppModel(
            skipBootstrap: true,
            defaults: defaults,
            libraryURL: makeTempLibraryURL("statistics")
        )
        model.libraryEntries = entries
        model.route = .statistics
        return model
    }

    private func entry(
        _ id: String,
        timing: Double?,
        audio: Double = 600,
        words: Int? = 100,
        daysAgo: Double = 0,
        model: String = "openai_whisper-large-v3_turbo",
        category: EntryCategory = .transcription
    ) -> LibraryEntry {
        var manifest = ParolaDocument.Manifest(
            createdAt: Self.reference.addingTimeInterval(-daysAgo * 86_400),
            originalAudioName: "\(id).wav",
            modelName: model,
            language: "en",
            category: category,
            durationSeconds: audio
        )
        manifest.transcriptionSeconds = timing
        manifest.wordCount = words
        return LibraryEntry(id: id, bundleURL: URL(fileURLWithPath: "/tmp/\(id).parola"), manifest: manifest)
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let previous = DefaultsStore.current
        let suite = temporaryDefaults("test-statistics-")
        DefaultsStore.current = suite
        defer { DefaultsStore.current = previous }
        try body(suite)
    }

    private func viewsPastEdges(of host: NSView, axis: Axis.Set) -> [String] {
        var names: [String] = []
        func walk(_ view: NSView) {
            for sub in view.subviews {
                // AppKit parks its key-view proxy off to the left of the window; it never draws.
                if String(describing: type(of: sub)) == "KeyViewProxy" { continue }
                let frame = sub.convert(sub.bounds, to: host)
                let pastSides = frame.minX < -0.5 || frame.maxX > host.bounds.width + 0.5
                let pastEnds = frame.minY < -0.5 || frame.maxY > host.bounds.height + 0.5
                if (axis.contains(.horizontal) && pastSides) || (axis.contains(.vertical) && pastEnds) {
                    names.append("\(type(of: sub)) \(frame)")
                }
                walk(sub)
            }
        }
        walk(host)
        return names
    }

    /// Spread over the year, two models (one past twelve hours, so the table's widest cell is measured), a longest and a
    /// fastest entry and a second kind, so every section of the page has something to draw.
    private var seededEntries: [LibraryEntry] {
        [
            entry("a", timing: 37.5),
            entry("b", timing: 1_205, audio: 12_500, daysAgo: 3),
            entry("c", timing: nil, daysAgo: 12),
            entry("d", timing: 20, audio: 3_600, daysAgo: 45),
            entry("e", timing: 90, audio: 900, words: nil, daysAgo: 200),
            entry("f", timing: 2_400, audio: 45_800, daysAgo: 60, model: "nvidia_parakeet-tdt-0.6b-v3"),
            entry("g", timing: 30, audio: 300, daysAgo: 7, category: .meeting),
        ]
    }

    /// Seeded through the view's own init: the `.task` that fills `stats` can't run inside a synchronous test body.
    private func populated() -> LibraryStatistics {
        LibraryStatistics.compute(entries: seededEntries, now: Self.reference, calendar: Calendar(identifier: .gregorian))
    }

    @Test("the populated page fits the detail column of every window it is given", arguments: [
        CGSize(width: 1180, height: 760), CGSize(width: MainWindowLayout.minimumWidth, height: MainWindowLayout.minimumHeight),
    ])
    func pageFitsTheWindow(size: CGSize) {
        withIsolatedDefaults { defaults in
            let model = makeModel(defaults, entries: seededEntries)
            // The narrowest the page can be in that window: the sidebar may take its widest.
            let width = size.width - MainWindowLayout.sidebarMaxWidth
            let host = NSHostingView(rootView: StatisticsView(stats: populated()).environment(model))
            host.frame = NSRect(x: 0, y: 0, width: width, height: size.height)
            host.layoutSubtreeIfNeeded()
            let overflowing = viewsPastEdges(of: host, axis: .horizontal)
            #expect(overflowing.isEmpty, "laid out past \(width)pt: \(overflowing.joined(separator: ", "))")
        }
    }

    /// The seed used to be `.empty`, so the route's first cross-fade frame was the empty state on a full library too.
    @Test("a library with entries waits for its numbers instead of claiming there are none")
    func populatedLibraryDoesNotFlashTheEmptyState() {
        let stats = populated()
        #expect(StatisticsPageState(libraryIsEmpty: false, stats: nil) == .waiting)
        #expect(StatisticsPageState(libraryIsEmpty: true, stats: nil) == .empty)
        #expect(StatisticsPageState(libraryIsEmpty: true, stats: stats) == .empty)
        guard case .summary(let shown) = StatisticsPageState(libraryIsEmpty: false, stats: stats) else {
            Issue.record("a library with entries and its numbers in hand shows the summary")
            return
        }
        #expect(shown == stats)
    }

    @Test("the tiles are the summary: no line under the title restates them, and the speed tile says real time")
    func totalsAreSaidOnce() {
        withIsolatedDefaults { defaults in
            let entries = [entry("a", timing: 60)]
            let model = makeModel(defaults, entries: entries)
            let page = HostedWindow(StatisticsView(stats: LibraryStatistics.compute(entries: entries)).environment(model))
            defer { page.close() }

            let words = HostedAccessibility.words(in: page.host)

            let restated = words.contains { $0.contains(" · ") && $0.hasSuffix(" transcribed") }
            #expect(!restated, "\(words)")
            #expect(words.contains("Average speed (× real time)"), "\(words)")
        }
    }

    @Test("VoiceOver finds the page title and each section as a heading")
    func sectionsAreHeadings() {
        withIsolatedDefaults { defaults in
            let entries = [entry("a", timing: 60), entry("b", timing: 30, daysAgo: 2)]
            let model = makeModel(defaults, entries: entries)
            let page = HostedWindow(StatisticsView(stats: LibraryStatistics.compute(entries: entries)).environment(model))
            defer { page.close() }

            let headings = HostedAccessibility.elements(in: page.host)
                .filter { $0.role == "AXHeading" }
                .compactMap { $0.name?.lowercased() }

            for title in ["statistics", "activity", "by model", "records"] {
                #expect(headings.contains(title), "\(title) in \(headings)")
            }
        }
    }

    @Test("an empty library's page says so once and offers the library's first step")
    func emptyPageOffersOpenFiles() {
        withIsolatedDefaults { defaults in
            let model = makeModel(defaults, entries: [])
            let page = HostedWindow(StatisticsView(stats: LibraryStatistics.compute(entries: [])).environment(model))
            defer { page.close() }

            let words = HostedAccessibility.words(in: page.host)

            #expect(words.contains("Open Files…"), "\(words)")
            #expect(words.contains("Transcripts you record or open appear here."), "\(words)")
            let counted = words.contains { $0.contains("0 transcripts") }
            #expect(!counted, "\(words)")
        }
    }

    @Test("an empty library renders the page without asking for more room than the smallest window")
    func emptyPageFitsTheSmallestWindow() {
        withIsolatedDefaults { defaults in
            let model = makeModel(defaults, entries: [])
            let host = NSHostingView(rootView: ContentView().environment(model))
            let wanted = host.fittingSize
            #expect(wanted.width <= MainWindowLayout.minimumWidth)
            #expect(wanted.height <= MainWindowLayout.minimumHeight)
        }
    }

    @Test("Statistics has no sidebar row, so its page lights none")
    func sidebarHighlightFollowsTheRoute() {
        let statistics = SidebarSelection.Page(
            route: .statistics, listShowing: false, searching: false, libraryFilter: .meeting, personFilter: nil
        )
        #expect(SidebarSelection.current(statistics, sidebarPeople: [], showsActivity: true, showsRecording: false) == nil)
    }

    @Test("opening the page drops the list the user was in")
    func openingStatisticsLeavesTheList() {
        withIsolatedDefaults { defaults in
            let model = makeModel(defaults, entries: [])
            model.libraryFilter = .meeting
            model.route = .transcript

            model.openStatistics()

            #expect(model.route == .statistics)
            #expect(model.libraryFilter == nil)
            #expect(model.isBrowsingLibrary == false)
        }
    }

    @Test("the route is named the way the bridge spells it")
    func routeRawValue() {
        #expect(AppModel.Route.statistics.rawValue == "statistics")
        #expect(AppModel.Route(rawValue: "statistics") == .statistics)
    }

    @Test("setRoute names the page among the routes it accepts")
    func setRouteAcceptsThePage() throws {
        try withIsolatedDefaults { defaults in
            let model = makeModel(defaults, entries: [])
            let server = try ParolaAutomationServer(model: model)
            let setRouteCommand = server.settingsCommands().first { $0.name == "setRoute" }
            let command = try #require(setRouteCommand)
            withExtendedLifetime(server) {}

            guard case .string(let options) = command.args.first(where: { $0.name == "route" })?.kind else {
                Issue.record("setRoute should constrain its route argument to an enum")
                return
            }
            #expect(options?.contains("statistics") == true)
        }
    }

    /// The bridge is how scenarios navigate; taking a shortcut past the helper would let it reach a state no click can.
    @Test("setRoute takes the page the way the menus do")
    func setRouteLeavesTheList() async throws {
        let previous = DefaultsStore.current
        DefaultsStore.current = temporaryDefaults("test-statistics-")
        defer { DefaultsStore.current = previous }
        let model = makeModel(DefaultsStore.current, entries: [])
        model.libraryFilter = .meeting
        model.route = .transcript
        model.searchQuery = "bianchi"
        model.searchRanking = []
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let command = try #require(server.settingsCommands().first { $0.name == "setRoute" })

        _ = try await command.handler(
            try command.validate(AutomationArgs(["route": .string("statistics")])),
            context
        )
        withExtendedLifetime(server) {}

        #expect(model.route == .statistics)
        #expect(model.libraryFilter == nil)
        #expect(model.searchRanking == nil)
    }

    @Test("a transcript opened from the page records no list to go back to")
    func statisticsIsNotAList() {
        let statistics = SidebarSelection.Page(
            route: .statistics, listShowing: false, searching: false, libraryFilter: nil, personFilter: nil
        )
        #expect(LibraryOrigin.capture(from: statistics) == nil)
    }

    @Test("a Records row opens the transcript it names")
    func recordRowOpensItsEntry() async throws {
        let previous = DefaultsStore.current
        DefaultsStore.current = temporaryDefaults("test-statistics-")
        defer { DefaultsStore.current = previous }
        let model = makeModel(DefaultsStore.current, entries: [])
        let seeded = try await model.library.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 9, text: "ordine del giorno")],
                language: "it", modelName: "m", durationSeconds: 9, transcriptionSeconds: 1
            ),
            audioSource: nil, title: "Assemblea"
        )
        model.libraryEntries = [seeded]
        let record = StatisticsRecord(kind: .longestRun, entry: seeded, value: "1 sec")

        RecordRow(record: record, showsAITitle: false, open: { model.loadEntry($0) }).activate()
        for _ in 0..<200 where model.selectedEntryID != seeded.id {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.selectedEntryID == seeded.id)
        #expect(model.route == .transcript)
        #expect(model.transcriptOrigin == nil)
    }
}
