import AppKit
import Foundation
import SwiftUI
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Library list layout", .serialized)
struct LibraryListLayoutTests {
    private struct Hosted {
        let model: AppModel
        let host: NSHostingView<AnyView>
        let window: NSWindow
    }

    private func entries(_ count: Int, hoursApart: Double = 1, from now: Date = Date()) -> [LibraryEntry] {
        (0..<count).map { index in
            let manifest = ParolaDocument.Manifest(
                createdAt: now.addingTimeInterval(-Double(index) * hoursApart * 3600),
                originalAudioName: "take-\(index).m4a",
                title: "Take \(index)",
                modelName: "stub",
                language: "en",
                durationSeconds: 60
            )
            let id = String(format: "%04d-layout", index)
            return LibraryEntry(id: id, bundleURL: URL(fileURLWithPath: "/tmp/LibraryListLayoutTests/\(id).parola"), manifest: manifest)
        }
    }

    /// Ordered in, far off screen and tall enough that every row is laid out.
    private func host(_ entries: [LibraryEntry], groupsByDate: Bool = true) async -> Hosted {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("list-layout"))
        await model.libraryRefreshTask?.value
        model.libraryGroupsByDate = groupsByDate
        model.libraryEntries = entries
        model.route = .transcript
        let host = NSHostingView(rootView: AnyView(ContentRoutes().environment(model)))
        let window = NSWindow(
            contentRect: NSRect(x: -12_000, y: -12_000, width: 940, height: 1_200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        let hosted = Hosted(model: model, host: host, window: window)
        _ = await settled(hosted) { table(hosted).map { $0.numberOfRows >= entries.count } ?? false }
        return hosted
    }

    private func close(_ hosted: Hosted) {
        hosted.window.orderOut(nil)
        hosted.window.contentView = nil
    }

    private func table(_ hosted: Hosted) -> NSTableView? {
        func walk(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap(walk).first
        }
        return walk(hosted.host)
    }

    private func settled(_ hosted: Hosted, until condition: (() -> Bool)? = nil) async -> Bool {
        for _ in 0..<(condition == nil ? 6 : 60) {
            hosted.host.layoutSubtreeIfNeeded()
            hosted.window.displayIfNeeded()
            if condition?() == true { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return condition?() ?? true
    }

    @Test("every entry row is 50 pt tall and the next one starts where it ends")
    func entryRowPitch() async throws {
        let shown = entries(6)
        let hosted = await host(shown, groupsByDate: false)
        defer { close(hosted) }
        let table = try #require(table(hosted))
        _ = await settled(hosted)

        // With the date titles off and nothing pinned, the entries are the list's last rows.
        let first = table.numberOfRows - shown.count
        #expect(first >= 0)
        for row in first..<table.numberOfRows {
            #expect(table.rect(ofRow: row).height == EntryRowMetrics.height, "row \(row): \(table.rect(ofRow: row))")
            if row > first {
                #expect(table.rect(ofRow: row).minY == table.rect(ofRow: row - 1).maxY, "row \(row) leaves a gap")
            }
        }
    }
}
