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

    private func entry(_ index: Int, at date: Date) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(
            createdAt: date,
            originalAudioName: "take-\(index).m4a",
            title: "Take \(index)",
            modelName: "stub",
            language: "en",
            durationSeconds: 60
        )
        let id = String(format: "%04d-layout", index)
        return LibraryEntry(id: id, bundleURL: URL(fileURLWithPath: "/tmp/LibraryListLayoutTests/\(id).parola"), manifest: manifest)
    }

    private func entries(_ count: Int, from now: Date = Date()) -> [LibraryEntry] {
        (0..<count).map { entry($0, at: now.addingTimeInterval(-Double($0) * 3600)) }
    }

    /// Today, Previous 7 Days and a month, whatever the time of day: seven rows once titled.
    private func threeGroups(from now: Date = Date()) -> [LibraryEntry] {
        [
            entry(0, at: now),
            entry(1, at: now.addingTimeInterval(-3 * 86_400)),
            entry(2, at: now.addingTimeInterval(-3 * 86_400 - 3_600)),
            entry(3, at: now.addingTimeInterval(-60 * 86_400)),
        ]
    }

    private func arrow(_ keyCode: UInt16, _ key: Int, in window: NSWindow) -> NSEvent? {
        let characters = UnicodeScalar(key).map { String(Character($0)) } ?? ""
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.numericPad, .function],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    /// The row selected after each press, as the table's own key handling moves it.
    private func press(_ keyCode: UInt16, _ key: Int, times: Int, on table: NSTableView, in hosted: Hosted) async throws -> [Int] {
        var selected: [Int] = []
        for _ in 0..<times {
            table.keyDown(with: try #require(arrow(keyCode, key, in: hosted.window)))
            _ = await settled(hosted)
            selected.append(table.selectedRow)
        }
        return selected
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

    @Test("a date title is a plain 32 pt row the arrow keys pass over, and Select All leaves it out")
    func titlesAreRowsTheKeyboardSkips() async throws {
        let hosted = await host(threeGroups())
        defer { close(hosted) }
        let table = try #require(table(hosted))
        _ = await settled(hosted)

        // Today, the take, Previous 7 Days, two takes, the month, the take: after whatever the page puts first.
        let first = table.numberOfRows - 7
        let titles = [first, first + 2, first + 5]
        let takes = [first + 1, first + 3, first + 4, first + 6]
        for row in titles {
            #expect(table.rect(ofRow: row).height == 32, "title row \(row): \(table.rect(ofRow: row))")
            let groupStyled = table.rowView(atRow: row, makeIfNecessary: true)?.isGroupRowStyle
            #expect(groupStyled == false, "title row \(row) is drawn as a system section header")
        }

        hosted.window.makeFirstResponder(table)
        table.selectRowIndexes([takes[0]], byExtendingSelection: false)
        _ = await settled(hosted)
        let down = try await press(125, NSDownArrowFunctionKey, times: 4, on: table, in: hosted)
        #expect(down == [takes[1], takes[2], takes[3], takes[3]])
        let up = try await press(126, NSUpArrowFunctionKey, times: 4, on: table, in: hosted)
        #expect(up == [takes[2], takes[1], takes[0], takes[0]])

        table.selectAll(nil)
        _ = await settled(hosted)
        #expect(Set(table.selectedRowIndexes) == Set(takes))
    }

    @Test("the page's top is the list's first row, and neither the arrow keys nor Select All land on it")
    func pageTopIsTheFirstRow() async throws {
        let shown = entries(3)
        let hosted = await host(shown, groupsByDate: false)
        defer { close(hosted) }
        let table = try #require(table(hosted))
        _ = await settled(hosted)

        #expect(table.numberOfRows == shown.count + 1)
        #expect(table.rect(ofRow: 0).height > 100, "the title, the chips and the intake strip: \(table.rect(ofRow: 0))")

        hosted.window.makeFirstResponder(table)
        table.selectRowIndexes([1], byExtendingSelection: false)
        _ = await settled(hosted)
        let up = try await press(126, NSUpArrowFunctionKey, times: 2, on: table, in: hosted)
        #expect(up == [1, 1])

        table.selectAll(nil)
        _ = await settled(hosted)
        #expect(Set(table.selectedRowIndexes) == [1, 2, 3])
    }

    @Test("a failure's banner opens up the list's first row, and the row closes again once it clears")
    func failureBannerGrowsTheTopRow() async throws {
        let hosted = await host(entries(3), groupsByDate: false)
        defer { close(hosted) }
        _ = await settled(hosted)
        // Looked up each time: a phase change may hand the page a table of its own.
        func topRow() -> CGFloat { table(hosted)?.rect(ofRow: 0).height ?? 0 }
        let calm = topRow()
        #expect(calm > 100)

        hosted.model.phase = .failed(message: "The file couldn't be decoded.")
        let grew = await settled(hosted) { topRow() > calm + 20 }
        #expect(grew, "row 0 stayed \(topRow()) pt")

        hosted.model.phase = .idle
        let shrank = await settled(hosted) { topRow() == calm }
        #expect(shrank, "row 0 stayed \(topRow()) pt")
    }

    @Test("titles and entries run as one list, and a group with no title adds no row")
    func itemsRunInOneList() {
        let now = Date()
        let displays = threeGroups(from: now).map { LibraryRowDisplay(entry: $0) }
        let titled = LibraryListItem.items(for: LibraryDateGroups.groups(for: displays, sortOrder: .newest, now: now))
        let kinds = titled.map { item -> String in
            if case .entry = item { return "take" }
            return "title"
        }
        #expect(kinds == ["title", "take", "title", "take", "take", "title", "take"])
        #expect(Set(titled.map(\.id)).count == titled.count, "every row has an id of its own")

        let untitled = LibraryListItem.items(for: LibraryDateGroups.ungrouped(displays))
        #expect(untitled.map(\.id) == displays.map(\.id))
    }
}
