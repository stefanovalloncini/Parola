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

    private func viewsPastSideEdges(of host: NSView) -> [String] {
        var names: [String] = []
        func walk(_ view: NSView) {
            for sub in view.subviews {
                // AppKit parks its key-view proxy off to the left of the window; it never draws.
                if String(describing: type(of: sub)) == "KeyViewProxy" { continue }
                let frame = sub.convert(sub.bounds, to: host)
                if frame.minX < -0.5 || frame.maxX > host.bounds.width + 0.5 {
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
            let overflowing = viewsPastSideEdges(of: host)
            #expect(overflowing.isEmpty, "laid out past \(width)pt with \(jobs) jobs: \(overflowing.joined(separator: ", "))")
        }
    }
}
