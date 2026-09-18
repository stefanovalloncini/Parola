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

    private func entry(_ id: String, timing: Double?, audio: Double = 600, words: Int = 100) -> LibraryEntry {
        var manifest = ParolaDocument.Manifest(
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

    @Test("the route reaches the page and the page fits the windows it is given", arguments: [
        CGSize(width: 1180, height: 760), CGSize(width: MainWindowLayout.minimumWidth, height: MainWindowLayout.minimumHeight),
    ])
    func pageFitsTheWindow(size: CGSize) {
        withIsolatedDefaults { defaults in
            let model = makeModel(defaults, entries: [
                entry("a", timing: 37.5),
                entry("b", timing: nil),
            ])
            let host = NSHostingView(rootView: ContentView().environment(model))
            host.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
            host.layoutSubtreeIfNeeded()
            let overflowing = viewsPastEdges(of: host, axis: .horizontal)
            #expect(overflowing.isEmpty, "laid out past \(size): \(overflowing.joined(separator: ", "))")
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
}
