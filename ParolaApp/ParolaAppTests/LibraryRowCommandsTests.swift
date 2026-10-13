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

    @Test("a pass that leaves the selection alone hands the menu an equal target")
    func targetIgnoresItsClosures() {
        func target(_ entries: [LibraryEntry], rename: @escaping (LibraryEntry) -> Void = { _ in }) -> LibraryRowsTarget {
            LibraryRowsTarget(entries: entries, rename: rename, delete: { _ in })
        }

        #expect(target([entry("a"), entry("b")]) == target([entry("a"), entry("b")], rename: { _ in print("other") }))
        #expect(target([entry("a")]) != target([entry("b")]))
        #expect(target([entry("a"), entry("b")]) != target([entry("a")]))
        #expect(target([entry("a"), entry("b")]) != target([entry("a", pinned: true), entry("b", pinned: true)]))
    }

    @Test("Pin pins a mixed selection, Unpin needs every row pinned, Rename needs one row")
    func targetNamesItsCommands() {
        func target(_ entries: [LibraryEntry]) -> LibraryRowsTarget {
            LibraryRowsTarget(entries: entries, rename: { _ in }, delete: { _ in })
        }

        let mixed = target([entry("a", pinned: true), entry("b")])
        let pinned = target([entry("a", pinned: true), entry("b", pinned: true)])
        let one = target([entry("a")])

        #expect(mixed.pins)
        #expect(!pinned.pins)
        #expect(mixed.renameTargetID == nil)
        #expect(one.renameTargetID == "a")
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

    @Test("Move to offers every category but the one all the rows already share")
    func moveOffersOtherCategories() {
        func entry(_ id: String, _ category: EntryCategory) -> LibraryEntry {
            let manifest = ParolaDocument.Manifest(originalAudioName: "\(id).m4a", modelName: "stub", language: "en", category: category)
            return LibraryEntry(id: id, bundleURL: URL(fileURLWithPath: "/tmp/LibraryRowCommandsTests/\(id).parola"), manifest: manifest)
        }

        let all = FeatureSet.all
        #expect(LibraryRowMenu.moveTargets(for: [entry("a", .meeting)], features: all) == [.transcription, .dictation])
        #expect(LibraryRowMenu.moveTargets(for: [entry("a", .meeting), entry("b", .meeting)], features: all) == [.transcription, .dictation])
        #expect(LibraryRowMenu.moveTargets(for: [entry("a", .meeting), entry("b", .dictation)], features: all) == EntryCategory.allCases)

        let gated = FeatureSet(enabled: [.meetings])
        #expect(LibraryRowMenu.moveTargets(for: [entry("a", .transcription)], features: gated) == [.meeting])
        #expect(LibraryRowMenu.moveTargets(for: [entry("a", .meeting)], features: gated) == [.transcription])
        #expect(LibraryRowMenu.moveTargets(for: [entry("a", .transcription)], features: FeatureSet(enabled: [])) == [])
    }

    @Test("a row's Export… opens it with the export sheet over it", .timeLimit(.minutes(1)))
    func exportOpensTheSheet() async throws {
        let model = makeModel("rowcommands-export")
        let entry = try await add("export me", to: model)
        await model.refreshLibraryAndWait()

        model.exportEntryFromLibrary(entry.id)

        let opened = await waitUntil { model.selectedEntryID == entry.id && model.exportSheetOpen }
        #expect(opened)
    }

    @Test("right-click builds one menu from the clicked rows, grouped, with Export and Share")
    func rowMenuIsGroupedForTheSelection() throws {
        let list = try Self.source("Views/LibraryRowList").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(list.contains("contextMenu(forSelectionType: LibraryEntry.ID.self) { ids in LibraryRowMenu("))
        #expect(!list.contains(".contextMenu {"), "no row carries a menu of its own")
        let order = [
            #"Button("Open")"#, #"Button("Open in New Window")"#, "Divider()", #"Button("Export…")"#, "share",
            "SendToMenu(", "Divider()", "pin", #"Button("Rename…")"#, "move", "Divider()", "reveal", "Divider()",
            #"Button("Delete", role: .destructive)"#,
        ]
        let single = try #require(list.range(of: "private func single("))
        var cursor = single.upperBound
        for item in order {
            let found = list.range(of: item, range: cursor..<list.endIndex)
            #expect(found != nil, "\(item) after the one before it")
            if let found { cursor = found.upperBound }
        }
        let actions = try #require(list.range(of: "struct LibraryRowActionButtons"))
        let export = try #require(list.range(of: #"Button("Export…")"#, range: actions.upperBound..<list.endIndex))
        let rename = try #require(list.range(of: #"Button("Rename…")"#, range: actions.upperBound..<list.endIndex))
        let reveal = try #require(list.range(of: #"Button("Reveal in Finder")"#, range: actions.upperBound..<list.endIndex))
        #expect(export.lowerBound < rename.lowerBound && rename.lowerBound < reveal.lowerBound)
    }

    @Test("both lists take Delete, the library list hands its rows to the File menu")
    func listsWireTheKeyboard() throws {
        let rows = try Self.source("Views/LibraryRowList")
        let trash = try Self.source("Views/MacRecentlyDeletedView")
        let app = try Self.source("ParolaApp")

        #expect(rows.contains(".onDeleteCommand(perform: deleteSelection)"))
        #expect(rows.contains(".focusedValue(\\.libraryRows, LibraryRowsTarget("))
        #expect(trash.contains(".onDeleteCommand(perform: confirmPurgeSelection)"))
        #expect(app.contains("CommandGroup(after: .newItem) {\n                LibraryRowCommands(model: model)"))
    }
}
