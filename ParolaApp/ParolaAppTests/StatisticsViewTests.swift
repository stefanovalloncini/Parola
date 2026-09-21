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
        _ id: String, timing: Double?, audio: Double = 600, words: Int? = 100, daysAgo: Double = 0
    ) -> LibraryEntry {
        var manifest = ParolaDocument.Manifest(
            createdAt: Self.reference.addingTimeInterval(-daysAgo * 86_400),
            originalAudioName: "\(id).wav",
            modelName: "openai_whisper-large-v3_turbo",
            language: "en",
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

    /// Spread over the year and with a longest and a fastest entry, so every section of the page has something to draw.
    private var seededEntries: [LibraryEntry] {
        [
            entry("a", timing: 37.5),
            entry("b", timing: 1_205, audio: 12_500, daysAgo: 3),
            entry("c", timing: nil, daysAgo: 12),
            entry("d", timing: 20, audio: 3_600, daysAgo: 45),
            entry("e", timing: 90, audio: 900, words: nil, daysAgo: 200),
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

    @Test("the sidebar lights the Statistics row and nothing else")
    func sidebarHighlightFollowsTheRoute() {
        #expect(
            SidebarRoute.selected(route: .statistics, searching: false, filter: .meeting, browsingAll: true)
                == .statistics
        )
        #expect(
            SidebarRoute.selected(route: .recentlyDeleted, searching: false, filter: nil, browsingAll: false)
                == .recentlyDeleted
        )
    }

    @Test("opening the page from the sidebar drops the list the user was in")
    func openingStatisticsLeavesTheList() {
        withIsolatedDefaults { defaults in
            let model = makeModel(defaults, entries: [])
            model.libraryFilter = .meeting
            model.libraryBrowsingAll = true
            model.route = .transcript

            model.openStatistics()

            #expect(model.route == .statistics)
            #expect(model.libraryFilter == nil)
            #expect(model.libraryBrowsingAll == false)
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
            let command = try #require(server.settingsCommands().first { $0.name == "setRoute" })
            withExtendedLifetime(server) {}

            guard case .string(let options) = command.args.first(where: { $0.name == "route" })?.kind else {
                Issue.record("setRoute should constrain its route argument to an enum")
                return
            }
            #expect(options?.contains("statistics") == true)
        }
    }

    /// The bridge is how scenarios navigate; taking a shortcut past the helper would let it reach a state no click can.
    @Test("setRoute takes the page the way the sidebar row does")
    func setRouteLeavesTheList() async throws {
        let previous = DefaultsStore.current
        DefaultsStore.current = temporaryDefaults("test-statistics-")
        defer { DefaultsStore.current = previous }
        let model = makeModel(DefaultsStore.current, entries: [])
        model.libraryFilter = .meeting
        model.libraryBrowsingAll = true
        model.route = .transcript
        model.searchQuery = "bianchi"
        model.searchResults = []
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
        #expect(model.libraryBrowsingAll == false)
        #expect(model.searchResults == nil)
    }

    @Test("a transcript opened from the page records no list to go back to")
    func statisticsIsNotAList() {
        #expect(LibraryOrigin.capture(sidebar: .statistics, homeOnScreen: false) == nil)
    }
}
