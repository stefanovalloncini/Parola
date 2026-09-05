import AppKit
import Foundation
import SwiftUI
import Testing
import ParolaCore
@testable import Parola

@MainActor
@Suite("Route layout", .serialized)
struct RouteLayoutTests {

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let previous = DefaultsStore.current
        let suite = UserDefaults(suiteName: "test-route-layout-\(UUID())")!
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
            defaults.set(true, forKey: "inspectorVisible")
            let model = makeModel(defaults, jobs: 0)
            model.transcript = Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 4, text: "the inspector folds away")],
                language: "en",
                modelName: "stub"
            )
            model.phase = .ready
            let host = NSHostingView(rootView: ContentView().environment(model))
            host.frame = NSRect(x: 0, y: 0, width: MainWindowLayout.minimumWidth, height: MainWindowLayout.minimumHeight)
            host.layoutSubtreeIfNeeded()
            #expect(defaults.bool(forKey: "inspectorVisible") == false)

            defaults.set(true, forKey: "inspectorVisible")
            host.layoutSubtreeIfNeeded()
            #expect(defaults.bool(forKey: "inspectorVisible") == true, "asking for it back at a narrow width must stick")

            host.frame = NSRect(x: 0, y: 0, width: 1400, height: MainWindowLayout.minimumHeight)
            host.layoutSubtreeIfNeeded()
            #expect(defaults.bool(forKey: "inspectorVisible") == true)
        }
    }

    @Test(
        "an empty route asks for no more height than the smallest window has",
        arguments: [AppModel.Route.queue, .batch, .transcript]
    )
    func emptyRoutesFitTheSmallestWindow(route: AppModel.Route) {
        withIsolatedDefaults { defaults in
            let model = makeModel(defaults, jobs: 0)
            model.route = route
            let host = NSHostingView(rootView: ContentView().environment(model))
            #expect(host.fittingSize.height <= MainWindowLayout.minimumHeight, "\(route) wants \(host.fittingSize.height)pt")
        }
    }
}
