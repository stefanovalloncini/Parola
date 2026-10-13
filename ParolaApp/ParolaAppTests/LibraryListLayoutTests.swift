import AppKit
import Foundation
import SwiftUI
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
@Suite("Library list layout", .serialized)
struct LibraryListLayoutTests {
    private struct Hosted {
        let model: AppModel
        let host: NSHostingView<AnyView>
        let window: NSWindow
    }

    private func entry(_ index: Int, at date: Date, labels: [String] = []) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(
            createdAt: date,
            originalAudioName: "take-\(index).m4a",
            title: "Take \(index)",
            modelName: "stub",
            language: "en",
            labels: labels,
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
    private func host(
        _ entries: [LibraryEntry], groupsByDate: Bool = true, headerPasses: LibraryHeaderPasses? = nil,
        withShelf: Bool = false
    ) async -> Hosted {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("list-layout"))
        await model.libraryRefreshTask?.value
        model.libraryGroupsByDate = groupsByDate
        // A filter that every test entry passes keeps the Recent shelf from taking three of the rows under test.
        if !withShelf { model.languageFilter = "EN" }
        model.libraryEntries = entries
        model.route = .transcript
        let host = NSHostingView(rootView: AnyView(
            ContentRoutes().environment(model).environment(\.libraryHeaderPasses, headerPasses)
        ))
        let window = KeyableWindow(
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

    @Test("the Recent shelf takes the three newest entries out of the list, and a sort that hides it puts them back")
    func shelfEntriesLeaveTheList() async throws {
        let shown = entries(8)
        let hosted = await host(shown, groupsByDate: false, withShelf: true)
        defer { close(hosted) }
        let table = try #require(table(hosted))
        _ = await settled(hosted)
        let shelved = table.numberOfRows
        #expect(shelved == 1 + 5, "the page top with its shelf, then the five other entries: \(shelved)")

        hosted.model.librarySortOrder = .oldest
        #expect(await settled(hosted) { table.numberOfRows == 1 + 8 }, "rows: \(table.numberOfRows)")

        hosted.model.librarySortOrder = .newest
        #expect(await settled(hosted) { table.numberOfRows == shelved }, "rows: \(table.numberOfRows)")
    }

    @Test("the shelf's tiles read as one element each, inside a Recent group")
    func shelfTilesAreElements() async throws {
        let shown = entries(8)
        let hosted = await host(shown, groupsByDate: false, withShelf: true)
        defer { close(hosted) }
        _ = await settled(hosted)
        let elements = HostedAccessibility.elements(in: hosted.host)
        for entry in shown.prefix(3) {
            let tile = try #require(elements.first { $0.identifier == "library.shelf.\(entry.id)" }, "\(entry.id)")
            #expect(tile.label?.hasPrefix("Take ") == true, "\(tile.label ?? "")")
            for action in ["Open", "Open in New Window", "Pin", "Rename…", "Delete"] {
                #expect(tile.actions.contains(action), "\(tile.actions)")
            }
        }
        #expect(!elements.contains { $0.identifier == "library.shelf.\(shown[3].id)" })
        #expect(elements.contains { $0.label == "Recent" })
    }

    @Test("Up from the first row climbs onto the shelf and Down comes back to it")
    func keyboardMovesBetweenShelfAndList() async throws {
        let hosted = await host(entries(8), groupsByDate: false, withShelf: true)
        defer { close(hosted) }
        let table = try #require(table(hosted))
        hosted.window.makeKey()
        hosted.window.makeFirstResponder(table)
        table.selectRowIndexes([1], byExtendingSelection: false)
        _ = await settled(hosted)

        func send(_ keyCode: UInt16) throws {
            let event = try #require(arrow(keyCode, 0, in: hosted.window))
            NSApp.sendEvent(event)
        }
        try send(126)
        #expect(await settled(hosted) { table.selectedRowIndexes.isEmpty }, "the first row gave the selection to a tile")
        try send(124)
        _ = await settled(hosted)
        #expect(table.selectedRowIndexes.isEmpty, "Right moves between tiles and leaves the rows alone")
        try send(125)
        #expect(await settled(hosted) { table.selectedRowIndexes == [1] }, "Down puts the selection on the first row: \(table.selectedRowIndexes)")
    }

    @Test("the rows keep to the reading column and the margins beside it still belong to the scroll view")
    func marginsStillScroll() async throws {
        let hosted = await host(entries(6), groupsByDate: false)
        defer { close(hosted) }
        let table = try #require(table(hosted))
        _ = await settled(hosted)

        let margin = EntryRowMetrics.columnMargin(paneWidth: hosted.host.bounds.width)
        #expect(margin > 0)
        let entryRow = table.numberOfRows - 1
        #expect(await settled(hosted) { table.rect(ofRow: entryRow).width <= EntryRowMetrics.columnWidth + 2 }, "rows span \(table.rect(ofRow: entryRow).width) pt of a \(hosted.host.bounds.width) pt pane")
        let scrollView = try #require(table.enclosingScrollView)
        #expect(scrollView.convert(scrollView.bounds, to: hosted.host).width == hosted.host.bounds.width, "the scroll view spans the pane, margins included")
    }

    @Test("a date title is a plain 47 pt row the arrow keys pass over, and Select All leaves it out")
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
            #expect(table.rect(ofRow: row).height == 47, "title row \(row): \(table.rect(ofRow: row))")
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
        #expect(table.rect(ofRow: 0).height > 60, "the title and the chips: \(table.rect(ofRow: 0))")

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
        #expect(calm > 60)

        hosted.model.phase = .failed(message: "The file couldn't be decoded.")
        let grew = await settled(hosted) { topRow() > calm + 20 }
        #expect(grew, "row 0 stayed \(topRow()) pt")

        hosted.model.phase = .idle
        let shrank = await settled(hosted) { topRow() == calm }
        #expect(shrank, "row 0 stayed \(topRow()) pt")
    }

    @Test("a failure brings the list back to its first row, where the banner sits, once per failure")
    func failureScrollsToTheBanner() async throws {
        let hosted = await host(entries(120), groupsByDate: false)
        defer { close(hosted) }
        func firstVisibleRow() -> Int {
            guard let table = table(hosted) else { return -1 }
            return table.rows(in: table.visibleRect).location
        }
        func scrollToTheEnd() {
            guard let table = table(hosted) else { return }
            table.scrollRowToVisible(table.numberOfRows - 1)
        }
        scrollToTheEnd()
        #expect(await settled(hosted) { firstVisibleRow() > 50 })

        hosted.model.phase = .failed(message: "The file couldn't be decoded.")
        let atTop = await settled(hosted) { firstVisibleRow() == 0 }
        #expect(atTop, "the list stayed at row \(firstVisibleRow())")

        scrollToTheEnd()
        let away = await settled(hosted) { firstVisibleRow() > 50 }
        await settle()
        #expect(away && firstVisibleRow() > 50, "the same failure pulled the list back to row \(firstVisibleRow())")

        hosted.model.phase = .failed(message: "The link couldn't be fetched.")
        let backAtTop = await settled(hosted) { firstVisibleRow() == 0 }
        #expect(backAtTop, "a new failure left the list at row \(firstVisibleRow())")
    }

    @Test("a failure over an open transcript draws the Library page's list, banner first")
    func failureOverATranscriptDrawsTheList() async throws {
        let shown = entries(3)
        let hosted = await host(shown, groupsByDate: false)
        defer { close(hosted) }
        hosted.model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "open")], language: "en", modelName: "stub"
        )
        hosted.model.phase = .ready
        _ = await settled(hosted)

        hosted.model.phase = .failed(message: "The file couldn't be decoded.")
        let listed = await settled(hosted) { (table(hosted)?.numberOfRows ?? 0) == shown.count + 1 }
        #expect(listed, "rows: \(table(hosted)?.numberOfRows ?? -1)")
    }

    @Test("a non-empty library's first scan rebuilds the rows once, not twice")
    func firstScanOfANonEmptyLibraryRebuildsOnce() async {
        let passes = LibraryRecomputePasses()
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("list-layout-first-scan"))
        // Cancelled before its first await resumes, so it returns without touching libraryEntries or libraryLoaded.
        model.libraryRefreshTask?.cancel()
        await model.libraryRefreshTask?.value
        model.route = .transcript
        let host = NSHostingView(rootView: AnyView(
            ContentRoutes().environment(model).environment(\.libraryRecomputePasses, passes)
        ))
        let window = NSWindow(
            contentRect: NSRect(x: -12_000, y: -12_000, width: 940, height: 1_200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        let hosted = Hosted(model: model, host: host, window: window)
        defer { close(hosted) }
        _ = await settled(hosted)
        let before = passes.count
        #expect(before > 0, "onAppear reports its own pass")

        model.libraryEntries = entries(1)
        model.libraryLoaded = true

        _ = await settled(hosted) { (table(hosted)?.numberOfRows ?? 0) > 0 }
        #expect(passes.count == before + 1, "version and loaded landing together rebuilt \(passes.count - before) times")
    }

    @Test("a row click leaves the header alone; the selection still reaches its bulk actions")
    func rowClickLeavesTheHeader() async throws {
        let passes = LibraryHeaderPasses()
        let hosted = await host(entries(6), groupsByDate: false, headerPasses: passes)
        defer { close(hosted) }
        let table = try #require(table(hosted))
        _ = await settled(hosted)
        let before = passes.count
        #expect(before > 0, "the header reports its passes")

        table.selectRowIndexes([2], byExtendingSelection: false)
        _ = await settled(hosted)
        table.selectRowIndexes([3], byExtendingSelection: false)
        _ = await settled(hosted)
        #expect(passes.count == before, "two clicks ran the header \(passes.count - before) more times")

        table.selectRowIndexes([3, 4], byExtendingSelection: false)
        let bulk = await settled(hosted) {
            HostedAccessibility.appKitElements(in: hosted.host).contains { $0.words.contains("Export (2)") }
        }
        #expect(bulk, "two rows picked bring Export into the header")
    }

    @Test("Labels, Language and the date come back as they were after a transcript opens and closes over the list")
    func filtersOutliveATranscript() async throws {
        let now = Date()
        let shown = (0..<6).map { index in
            entry(index, at: now.addingTimeInterval(-Double(index) * 3600), labels: index < 2 ? ["Work"] : [])
        }
        let hosted = await host(shown, groupsByDate: false)
        defer { close(hosted) }
        hosted.model.labelFilter = "Work"
        hosted.model.dateRangeFilter = .month
        #expect(await settled(hosted) { table(hosted)?.numberOfRows == 3 }, "the page top and the two Work rows")
        let firstList = try #require(table(hosted))

        hosted.model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "open")], language: "en", modelName: "stub"
        )
        hosted.model.phase = .ready
        #expect(await settled(hosted) { ContentRoutes.routeID(for: hosted.model) == .phase })
        await settle(for: .milliseconds(600))

        hosted.model.transcript = nil
        hosted.model.phase = .idle
        let back = await settled(hosted) { table(hosted).map { $0 !== firstList && $0.numberOfRows > 0 } ?? false }
        #expect(back, "the list was mounted again")
        #expect(table(hosted)?.numberOfRows == 3, "rows: \(table(hosted)?.numberOfRows ?? -1)")
        #expect(hosted.model.labelFilter == "Work")
        #expect(hosted.model.dateRangeFilter == .month)
    }

    @Test("VoiceOver meets each entry row as one element, read as one sentence, with its actions at hand")
    func rowsReadAsOneElement() async throws {
        let shown = entries(3)
        let hosted = await host(shown, groupsByDate: false)
        defer { close(hosted) }
        _ = await settled(hosted)
        let elements = HostedAccessibility.elements(in: hosted.host)
        let row = try #require(elements.first { $0.identifier == "library.row.\(shown[0].id)" })
        let length = try #require(LibraryRowFormat.spokenDuration(shown[0].durationSeconds))
        #expect(row.label?.hasPrefix("Take 0, ") == true, "\(row.label ?? "")")
        #expect(row.label?.hasSuffix(", \(length)") == true, "\(row.label ?? "")")
        #expect(!elements.contains { $0.label == "Take 0" || $0.value == "Take 0" }, "the title is not an element of its own")
        for action in ["Open", "Open in New Window", "Pin", "Rename…", "Reveal in Finder", "Delete"] {
            #expect(row.actions.contains(action), "\(row.actions)")
        }
        let subtitle = LibraryPageHeader.spokenSubtitle(count: 3, totalSeconds: 180)
        #expect(elements.contains { $0.words.contains(subtitle) }, "the page's subtitle reads \(subtitle)")
    }

    @Test("a thousand entries fill the list as rows under their headers")
    func thousandEntriesOnScreen() async throws {
        let shown = entries(1_000)
        let clock = ContinuousClock()
        let start = clock.now
        let hosted = await host(shown)
        defer { close(hosted) }
        let table = try #require(table(hosted))
        let onScreen = clock.now - start
        print("SCALE 1,000 entries hosted: \(table.numberOfRows) table rows ready in \(onScreen)")

        let headers = LibraryDateGroups.Headers(sortOrder: .newest, groupsByDate: true)
        let items = LibraryListItem.items(for: headers.groups(for: shown.map { LibraryRowDisplay(entry: $0, when: headers.when(for: $0)) }))
        #expect(table.numberOfRows == items.count + 1, "the page top, then every title and entry")
    }

    @Test("no row draws a system rule under it; an entry's own hairline starts at its text")
    func rowsDrawNoRule() async throws {
        let hosted = await host(threeGroups())
        defer { close(hosted) }
        let table = try #require(table(hosted))
        _ = await settled(hosted)
        let rep = try #require(table.bitmapImageRepForCachingDisplay(in: table.bounds))
        table.cacheDisplay(in: table.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / table.bounds.width
        let columns = Array(stride(from: Int(120 * scale), to: Int((table.bounds.width - 40) * scale), by: 2))
        let margin = EntryRowMetrics.columnMargin(paneWidth: table.bounds.width)
        let gutter = Array(stride(from: Int((margin + 2) * scale), to: Int((margin + 14) * scale), by: 2))
        func inked(row y: Int) -> Int {
            columns.count(where: { (rep.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.02 })
        }
        func gutterInked(row y: Int) -> Int {
            gutter.count(where: { (rep.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.02 })
        }

        // Today, the take, …: the take's time and length sit inside the columns read.
        let take = table.rect(ofRow: table.numberOfRows - 6)
        let drawn = (Int(take.minY * scale)..<Int(take.maxY * scale)).contains { inked(row: $0) > 0 }
        #expect(drawn, "the render holds no rows, so it can't show a rule either")
        // The list draws a rule as a faint line across the whole row, in the row's last point.
        var ruled: [Int] = []
        for row in 0..<(table.numberOfRows - 1) {
            let rect = table.rect(ofRow: row)
            if (Int((rect.maxY - 1) * scale)..<Int(rect.maxY * scale)).contains(where: { gutterInked(row: $0) > gutter.count * 9 / 10 }) {
                ruled.append(row)
            }
        }
        #expect(ruled.isEmpty, "rows with a rule under them: \(ruled)")
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
