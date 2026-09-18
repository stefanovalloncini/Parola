import AppKit
import Foundation
import SwiftUI
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Route layout", .serialized)
struct RouteLayoutTests {

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let previous = DefaultsStore.current
        let suite = temporaryDefaults("test-route-layout-")
        DefaultsStore.current = suite
        defer { DefaultsStore.current = previous }
        try body(suite)
    }

    private func makeModel(_ defaults: UserDefaults, jobs: Int) -> AppModel {
        let model = AppModel(
            skipBootstrap: true,
            defaults: defaults,
            libraryURL: makeTempLibraryURL("route-layout")
        )
        model.batchJobs = (0..<jobs).map {
            BatchJob(url: URL(fileURLWithPath: "/tmp/route-layout/file-\($0).wav"), status: .done)
        }
        return model
    }

    private func hostedWindow(_ model: AppModel, width: CGFloat, height: CGFloat) -> NSView {
        let host = NSHostingView(rootView: ContentView().environment(model))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        return host
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

    private func makeReadyModel(_ defaults: UserDefaults) -> AppModel {
        let model = makeModel(defaults, jobs: 0)
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 4, text: "the inspector folds away")],
            language: "en",
            modelName: "stub"
        )
        model.phase = .ready
        return model
    }

    /// The pane reads its width during layout and hides the inspector from the pass after that, so give it two.
    private func settle(_ host: NSView, width: CGFloat, height: CGFloat) {
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
    }

    private func hasInspectorColumn(_ host: NSView) -> Bool {
        var found = false
        func walk(_ view: NSView) {
            for sub in view.subviews {
                let frame = sub.convert(sub.bounds, to: host)
                if abs(frame.width - MainWindowLayout.inspectorWidth) < 0.5,
                   abs(frame.maxX - host.bounds.width) < 0.5 {
                    found = true
                }
                walk(sub)
            }
        }
        walk(host)
        return found
    }

    @Test("the batch queue and its export panel fit the smallest window")
    func batchColumnsFitTheSmallestWindow() {
        #expect(MainWindowLayout.sidebarMaxWidth + MainWindowLayout.batchPaneMinWidth <= MainWindowLayout.minimumWidth)
    }

    @Test(
        "the batch route stays inside the window at every supported width",
        arguments: [MainWindowLayout.minimumWidth, 1180, 1600] as [CGFloat], [0, 3]
    )
    func batchRouteFitsTheWindow(width: CGFloat, jobs: Int) {
        withIsolatedDefaults { defaults in
            let model = makeModel(defaults, jobs: jobs)
            model.route = .batch
            let host = hostedWindow(model, width: width, height: MainWindowLayout.minimumHeight)
            let overflowing = viewsPastEdges(of: host, axis: .horizontal)
            #expect(overflowing.isEmpty, "laid out past \(width)pt with \(jobs) jobs: \(overflowing.joined(separator: ", "))")
        }
    }

    @Test("nothing in the batch route is laid out past the edges of the narrowest detail column", arguments: [0, 3])
    func batchFitsDetailColumn(jobs: Int) {
        withIsolatedDefaults { defaults in
            let model = makeModel(defaults, jobs: jobs)
            let host = NSHostingView(rootView: BatchView().environment(model))
            let detailWidth = MainWindowLayout.minimumWidth - MainWindowLayout.sidebarMaxWidth
            host.frame = NSRect(x: 0, y: 0, width: detailWidth, height: MainWindowLayout.minimumHeight)
            host.layoutSubtreeIfNeeded()
            let overflowing = viewsPastEdges(of: host, axis: .horizontal)
            #expect(overflowing.isEmpty, "laid out past \(detailWidth)pt with \(jobs) jobs: \(overflowing.joined(separator: ", "))")
        }
    }

    @Test(
        "the queue route fits the window it is given",
        arguments: [CGSize(width: 1180, height: 760), CGSize(width: 920, height: 700)], [0, 3]
    )
    func queueRouteFitsTheWindow(size: CGSize, jobs: Int) {
        withIsolatedDefaults { defaults in
            let model = makeModel(defaults, jobs: jobs)
            model.route = .queue
            let host = hostedWindow(model, width: size.width, height: size.height)
            let overflowing = viewsPastEdges(of: host, axis: [.horizontal, .vertical])
            #expect(overflowing.isEmpty, "laid out past \(size) with \(jobs) jobs: \(overflowing.joined(separator: ", "))")
        }
    }

    @Test("the inspector folds away on a narrow window and comes back when it widens")
    func inspectorFoldsAwayOnNarrowWindows() {
        withIsolatedDefaults { defaults in
            let model = makeReadyModel(defaults)
            let host = NSHostingView(rootView: ContentView().environment(model))
            settle(host, width: MainWindowLayout.minimumWidth, height: MainWindowLayout.minimumHeight)
            #expect(hasInspectorColumn(host) == false)

            settle(host, width: 1400, height: MainWindowLayout.minimumHeight)
            #expect(hasInspectorColumn(host), "widening must bring the inspector back with no user toggle")
        }
    }

    @Test("layout never writes the inspector preference")
    func foldingAwayLeavesThePreferenceAlone() {
        withIsolatedDefaults { defaults in
            defaults.set(true, forKey: InspectorVisibility.preferenceKey)
            let model = makeReadyModel(defaults)
            let host = NSHostingView(rootView: ContentView().environment(model))
            settle(host, width: MainWindowLayout.minimumWidth, height: MainWindowLayout.minimumHeight)
            #expect(defaults.object(forKey: InspectorVisibility.preferenceKey) as? Bool == true)
            #expect(hasInspectorColumn(host) == false)
        }
    }

    @Test("asking for the inspector at a narrow width survives a rebuilt pane, and widening forgets it")
    func inspectorOverrideSurvivesARebuild() {
        withIsolatedDefaults { defaults in
            let model = makeReadyModel(defaults)
            let host = NSHostingView(rootView: ContentView().environment(model))
            settle(host, width: MainWindowLayout.minimumWidth, height: MainWindowLayout.minimumHeight)
            #expect(hasInspectorColumn(host) == false)

            InspectorVisibility.toggle(in: defaults, isNarrow: model.transcriptPaneIsNarrow)
            settle(host, width: MainWindowLayout.minimumWidth, height: MainWindowLayout.minimumHeight)
            #expect(hasInspectorColumn(host), "an explicit ask at a narrow width shows the inspector")

            let rebuilt = NSHostingView(rootView: ContentView().environment(model))
            settle(rebuilt, width: MainWindowLayout.minimumWidth, height: MainWindowLayout.minimumHeight)
            #expect(hasInspectorColumn(rebuilt), "the ask outlives the pane it was made in")

            settle(rebuilt, width: 1400, height: MainWindowLayout.minimumHeight)
            #expect(defaults.bool(forKey: InspectorVisibility.forcedAtNarrowWidthKey) == false)
        }
    }

    @Test("the toggle flips the key that the current width answers to")
    func toggleFlipsTheKeyForTheWidth() {
        let defaults = temporaryDefaults("test-inspector-")
        InspectorVisibility.toggle(in: defaults, isNarrow: true)
        #expect(defaults.bool(forKey: InspectorVisibility.forcedAtNarrowWidthKey) == true)
        #expect(InspectorVisibility.preference(in: defaults) == true)

        InspectorVisibility.toggle(in: defaults, isNarrow: false)
        #expect(InspectorVisibility.preference(in: defaults) == false)
        #expect(defaults.bool(forKey: InspectorVisibility.forcedAtNarrowWidthKey) == true)
    }

    @Test(
        "a populated route asks for no more room than the smallest window has",
        arguments: [AppModel.Route.queue, .batch]
    )
    func populatedRoutesFitTheSmallestWindow(route: AppModel.Route) {
        withIsolatedDefaults { defaults in
            let model = makeModel(defaults, jobs: 3)
            model.route = route
            let host = NSHostingView(rootView: ContentView().environment(model))
            let wanted = host.fittingSize
            #expect(wanted.width <= MainWindowLayout.minimumWidth, "\(route) wants \(wanted.width)pt of width")
            #expect(wanted.height <= MainWindowLayout.minimumHeight, "\(route) wants \(wanted.height)pt of height")
        }
    }

    @Test(
        "an empty route asks for no more height than the smallest window has",
        arguments: [AppModel.Route.queue, .batch, .transcript, .statistics]
    )
    func emptyRoutesFitTheSmallestWindow(route: AppModel.Route) {
        withIsolatedDefaults { defaults in
            let model = makeModel(defaults, jobs: 0)
            model.route = route
            let host = NSHostingView(rootView: ContentView().environment(model))
            let wanted = host.fittingSize
            #expect(wanted.width <= MainWindowLayout.minimumWidth, "\(route) wants \(wanted.width)pt of width")
            #expect(wanted.height <= MainWindowLayout.minimumHeight, "\(route) wants \(wanted.height)pt of height")
        }
    }
}
