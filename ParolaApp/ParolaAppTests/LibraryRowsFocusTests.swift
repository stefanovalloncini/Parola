import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Library rows focused value", .serialized)
struct LibraryRowsFocusTests {
    @MainActor
    private final class Probe {
        var ids: [LibraryEntry.ID]?
        var reads = 0
    }

    private struct Reader: View {
        @FocusedValue(\.libraryRows) private var rows
        let probe: Probe

        var body: some View {
            Color.clear
                .frame(width: 1, height: 1)
                .onChange(of: rows?.ids, initial: true) {
                    probe.ids = rows?.ids
                    probe.reads += 1
                }
        }
    }

    private struct Harness: View {
        let items: [LibraryListItem]
        let probe: Probe
        @State private var selection: Set<LibraryEntry.ID> = ["b"]
        @State private var pendingBulkDelete = false
        @FocusState private var focus: LibraryListFocus?

        var body: some View {
            VStack(spacing: 0) {
                LibraryRowList<EmptyView>(
                    items: items,
                    selection: $selection,
                    detail: .excerpt,
                    animatesRows: false,
                    rename: { _ in },
                    pendingBulkDelete: $pendingBulkDelete,
                    focus: $focus,
                    focusKey: .browse
                )
                Reader(probe: probe)
            }
            .onAppear { focus = .browse }
        }
    }

    private func entry(_ id: String) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(originalAudioName: "\(id).m4a", modelName: "stub", language: "en")
        return LibraryEntry(id: id, bundleURL: URL(fileURLWithPath: "/tmp/LibraryRowsFocusTests/\(id).parola"), manifest: manifest)
    }

    @Test("the focused list hands the File menu its selected rows")
    func focusedListPublishesItsSelection() async throws {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            filePicker: TestFilePicker(),
            libraryURL: makeTempLibraryURL("library-rows-focus")
        )
        let probe = Probe()
        let items = ["a", "b", "c"].map { LibraryListItem.entry(LibraryRowDisplay(entry: entry($0))) }
        let hosted = HostedWindow(Harness(items: items, probe: probe).environment(model), width: 600, height: 400, toolbar: true)
        defer { hosted.close() }
        hosted.window.makeKeyAndOrderFront(nil)
        if let table = hosted.table { hosted.window.makeFirstResponder(table) }
        await waitUntil { probe.ids == ["b"] }
        #expect(probe.ids == ["b"])
    }
}
