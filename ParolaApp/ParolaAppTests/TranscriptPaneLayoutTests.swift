import AppKit
import Foundation
import SwiftUI
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Transcript pane layout", .serialized)
struct TranscriptPaneLayoutTests {

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let previous = DefaultsStore.current
        let suite = temporaryDefaults("test-pane-layout-")
        DefaultsStore.current = suite
        defer { DefaultsStore.current = previous }
        try body(suite)
    }

    private func makeModel(_ defaults: UserDefaults) -> AppModel {
        let model = AppModel(
            skipBootstrap: true,
            defaults: defaults,
            libraryURL: makeTempLibraryURL("pane-layout")
        )
        model.transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 4, text: "the sidebar and the inspector share one window"),
                TranscriptSegment(id: 1, start: 4, end: 9, text: "and neither of them may run past its edge")
            ],
            language: "en",
            modelName: "stub"
        )
        model.phase = .ready
        return model
    }

    private func viewsOutsideBounds(of host: NSView) -> [String] {
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

    @Test("the sidebar at its widest and the transcript pane at its narrowest fit the smallest window")
    func columnsFitTheSmallestWindow() {
        #expect(MainWindowLayout.sidebarMaxWidth + MainWindowLayout.transcriptPaneMinWidth <= MainWindowLayout.minimumWidth)
    }

    @Test("the whole window keeps its columns inside its edges at every supported width",
          arguments: [MainWindowLayout.minimumWidth, 930, 950, 1180, 1500] as [CGFloat])
    func windowFitsAtEveryWidth(width: CGFloat) {
        withIsolatedDefaults { defaults in
            defaults.set(true, forKey: "inspectorVisible")
            let model = makeModel(defaults)
            let host = NSHostingView(rootView: ContentView().environment(model))
            host.frame = NSRect(x: 0, y: 0, width: width, height: MainWindowLayout.minimumHeight)
            host.layoutSubtreeIfNeeded()
            let overflowing = viewsOutsideBounds(of: host)
            #expect(overflowing.isEmpty, "laid out past \(width)pt: \(overflowing.joined(separator: ", "))")
        }
    }

    @Test("nothing is laid out past the edges of the narrowest detail column")
    func paneFitsDetailColumn() {
        withIsolatedDefaults { defaults in
            defaults.set(true, forKey: "inspectorVisible")
            let model = makeModel(defaults)
            let detailWidth = MainWindowLayout.minimumWidth - MainWindowLayout.sidebarMaxWidth
            let host = NSHostingView(rootView: TranscriptPane().environment(model))
            host.frame = NSRect(x: 0, y: 0, width: detailWidth, height: MainWindowLayout.minimumHeight)
            host.layoutSubtreeIfNeeded()
            let overflowing = viewsOutsideBounds(of: host)
            #expect(overflowing.isEmpty, "laid out past \(detailWidth)pt: \(overflowing.joined(separator: ", "))")
        }
    }
}
