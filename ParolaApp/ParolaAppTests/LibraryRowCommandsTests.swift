import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Library rows from the keyboard and the menus")
struct LibraryRowCommandsTests {

    private func makeModel(_ label: String) -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL(label))
    }

    private func add(_ text: String, to model: AppModel) async throws -> LibraryEntry {
        try await model.library.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil
        )
    }

    private func entry(_ id: String, pinned: Bool = false) -> LibraryEntry {
        var manifest = ParolaDocument.Manifest(originalAudioName: "\(id).m4a", modelName: "stub", language: "en")
        manifest.pinned = pinned
        return LibraryEntry(id: id, bundleURL: URL(fileURLWithPath: "/tmp/LibraryRowCommandsTests/\(id).parola"), manifest: manifest)
    }

    private func row(_ entry: LibraryEntry) -> LibraryListItem {
        .entry(LibraryRowDisplay(entry: entry))
    }

    private static func source(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/LibraryRowCommandsTests.swift",
            with: "ParolaApp/\(name).swift"
        )
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    @Test("the menu acts on the selected entries in list order, never on a date title")
    func targetTakesTheSelectedEntries() {
        let items: [LibraryListItem] = [
            .header(id: "today", title: "Today"), row(entry("a")), row(entry("b")), row(entry("c")),
        ]

        let picked = LibraryRowsTarget.selectedEntries(["c", "a", "header/today"], in: items)

        #expect(picked.map(\.id) == ["a", "c"])
    }

    @Test("Pin pins a mixed selection, Unpin needs every row pinned, Rename needs one row")
    func targetNamesItsCommands() {
        func target(_ entries: [LibraryEntry]) -> LibraryRowsTarget {
            LibraryRowsTarget(entries: entries, rename: { _ in }, delete: {})
        }

        let mixed = target([entry("a", pinned: true), entry("b")])
        let pinned = target([entry("a", pinned: true), entry("b", pinned: true)])
        let one = target([entry("a")])

        #expect(mixed.pins)
        #expect(!pinned.pins)
        #expect(mixed.renameTarget == nil)
        #expect(one.renameTarget?.id == "a")
    }

    @Test("Delete takes one row at once and asks first for several")
    func deleteAsksOnlyForSeveral() {
        #expect(LibraryDeleteRequest.forSelection(count: 0) == .none)
        #expect(LibraryDeleteRequest.forSelection(count: 1) == .now)
        #expect(LibraryDeleteRequest.forSelection(count: 3) == .confirm)
    }

    @Test("Pin from the menu pins every selected row", .timeLimit(.minutes(1)))
    func pinActsOnTheSelection() async throws {
        let model = makeModel("rowcommands-pin")
        let first = try await add("first", to: model)
        let second = try await add("second", to: model)
        await model.refreshLibraryAndWait()

        model.setPinned(true, for: [first.id, second.id])

        let pinned = await waitUntil {
            model.libraryEntry(id: first.id)?.pinned == true && model.libraryEntry(id: second.id)?.pinned == true
        }
        #expect(pinned)
    }

    @Test("both lists take Delete, the library list hands its rows to the File menu")
    func listsWireTheKeyboard() throws {
        let rows = try Self.source("Views/LibraryRowList")
        let trash = try Self.source("Views/MacRecentlyDeletedView")
        let app = try Self.source("ParolaApp")

        #expect(rows.contains(".onDeleteCommand(perform: deleteSelection)"))
        #expect(rows.contains(".focusedValue(\\.libraryRows"))
        #expect(trash.contains(".onDeleteCommand(perform: confirmPurgeSelection)"))
        #expect(app.contains("CommandGroup(after: .newItem) {\n                LibraryRowCommands(model: model)"))
    }
}
