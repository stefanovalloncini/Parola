import AppKit
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaDictation
import ParolaTestSupport

@MainActor
@Suite("Rule list panes", .serialized)
struct RuleListPanesTests {
    /// The panes that search, filter and sort their rules once the list is long.
    enum Pane: CaseIterable, Sendable {
        case snippets, corrections, ignoredSegments, findReplace, autoExport

        var prefix: String {
            switch self {
            case .snippets: "Snippets"
            case .corrections: "Corrections"
            case .ignoredSegments: "IgnoredSegments"
            case .findReplace: "FindReplace"
            case .autoExport: "AutoExport"
            }
        }

        var list: EditableList { EditableList(rawPane: self) }

        /// The field each row starts with.
        var firstField: String {
            switch self {
            case .snippets: "Snippets.TextField.Trigger"
            case .corrections: "Corrections.TextField.From"
            case .ignoredSegments: "IgnoredSegments.TextField.Pattern"
            case .findReplace: "FindReplace.TextField.Find"
            case .autoExport: "AutoExport.TextField.Extensions"
            }
        }
    }

    /// Every pane whose list is edited with + and −.
    enum EditableList: CaseIterable, Sendable {
        case snippets, corrections, ignoredSegments, findReplace, autoExport, watchedFolders, sendTo, prompts

        init(rawPane: Pane) {
            switch rawPane {
            case .snippets: self = .snippets
            case .corrections: self = .corrections
            case .ignoredSegments: self = .ignoredSegments
            case .findReplace: self = .findReplace
            case .autoExport: self = .autoExport
            }
        }

        var prefix: String {
            switch self {
            case .snippets: "Snippets"
            case .corrections: "Corrections"
            case .ignoredSegments: "IgnoredSegments"
            case .findReplace: "FindReplace"
            case .autoExport: "AutoExport"
            case .watchedFolders: "WatchedFolders"
            case .sendTo: "SendTo"
            case .prompts: "Prompts"
            }
        }

        var removeLabel: String {
            switch self {
            case .snippets: String(localized: "Remove Snippet")
            case .corrections: String(localized: "Remove Correction")
            case .ignoredSegments: String(localized: "Remove Pattern")
            case .findReplace, .autoExport: String(localized: "Remove Rule")
            case .watchedFolders: String(localized: "Remove Folder")
            case .sendTo: String(localized: "Remove Destination")
            case .prompts: String(localized: "Delete prompt")
            }
        }

        /// Send To offers its kinds of destination from the + menu; the rest add straight away.
        var addSuffix: String { self == .sendTo ? "\(prefix).Menu.Add" : "\(prefix).Button.Add" }

        @MainActor @ViewBuilder var view: some View {
            switch self {
            case .snippets: SnippetsPane()
            case .corrections: CorrectionsPane()
            case .ignoredSegments: IgnoredSegmentsPane()
            case .findReplace: FindReplacePane()
            case .autoExport: AutoExportPane()
            case .watchedFolders: WatchedFoldersPane()
            case .sendTo: SendToPane()
            case .prompts: PromptsPane()
            }
        }

        /// The names of the listed rules, in list order.
        @MainActor func names(_ model: AppModel) async -> [String] {
            switch self {
            case .snippets: model.snippets.map(\.trigger)
            case .corrections: model.correctionRules.map(\.from)
            case .ignoredSegments: model.ignoredSegmentRules.map(\.pattern)
            case .findReplace: model.findReplaceRules.map(\.find)
            case .autoExport: model.autoExportRules.map { $0.sourceExtensions.sorted().joined() }
            case .watchedFolders: model.watchedFolders.folders.map(\.displayName)
            case .sendTo: model.destinations.map(\.name)
            case .prompts: await model.promptLibrary.userPrompts.map(\.name)
            }
        }
    }

    @MainActor
    private struct Hosted {
        let model: AppModel
        let window: HostedWindow
        let folders: URL?

        func close() async {
            window.close()
            if folders != nil { await model.watchedFolders.stopWatching() }
            if let folders { try? FileManager.default.removeItem(at: folders) }
        }
    }

    private func makeModel(_ defaults: UserDefaults = temporaryDefaults()) -> AppModel {
        AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("rule-lists"))
    }

    private func fill(_ list: EditableList, _ model: AppModel, words: [String]) async {
        switch list {
        case .snippets: model.snippets = words.map { Snippet(trigger: $0, replacement: $0.uppercased()) }
        case .corrections: model.correctionRules = words.map { CorrectionRule(from: $0, to: $0.uppercased()) }
        case .ignoredSegments: model.ignoredSegmentRules = words.map { IgnoredSegmentRule(pattern: $0) }
        case .findReplace: model.findReplaceRules = words.map { FindReplaceRule(find: $0, replace: $0.uppercased()) }
        case .autoExport: model.autoExportRules = words.map { AutoExportRule(sourceExtensions: [$0], presetIDs: []) }
        case .sendTo:
            model.setDestinations(words.map {
                .obsidianFolder(ObsidianVaultFolderDestination(
                    name: $0, vaultBookmark: Data([0x01]), vaultPath: "/tmp/parola-rule-lists/\($0)"
                ))
            })
        case .prompts:
            for word in words {
                _ = await model.promptLibrary.addUserPrompt(name: word, instructions: "Do it", triggerWords: [], useSystemInstructions: true)
            }
        case .watchedFolders:
            break
        }
    }

    /// Watched folders come from the store's saved list, so they are written before the model first reads it.
    private func host(_ list: EditableList, words: [String]) async throws -> Hosted {
        let defaults = temporaryDefaults()
        var folders: URL?
        if list == .watchedFolders {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("parola-rule-lists-\(UUID().uuidString)", isDirectory: true)
            var saved: [WatchedFolder] = []
            for word in words {
                let folder = root.appendingPathComponent(word, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                saved.append(WatchedFolder(bookmark: bookmark, displayPath: folder.path))
            }
            defaults.set(try JSONEncoder().encode(saved), forKey: "watchedFolders")
            folders = root
        }
        let model = makeModel(defaults)
        await fill(list, model, words: words)
        let window = HostedWindow(list.view.environment(model), width: 900, height: 1600)
        let hosted = Hosted(model: model, window: window, folders: folders)
        await waitUntil { rows(list, in: hosted).count == words.count }
        return hosted
    }

    private func elements(_ hosted: Hosted) -> [HostedAccessibility.Element] {
        hosted.window.host.layoutSubtreeIfNeeded()
        return HostedAccessibility.elements(in: hosted.window.host)
    }

    private func element(_ suffix: String, in hosted: Hosted) -> HostedAccessibility.Element? {
        elements(hosted).first { $0.identifier?.hasSuffix(suffix) == true }
    }

    /// SwiftUI hands VoiceOver the field's cell; the field is its control view.
    private func textField(_ suffix: String, in hosted: Hosted) -> NSTextField? {
        let object = element(suffix, in: hosted)?.object
        return object as? NSTextField ?? (object as? NSCell)?.controlView as? NSTextField
    }

    /// Top to bottom on screen.
    private func rows(_ list: EditableList, in hosted: Hosted) -> [HostedAccessibility.Element] {
        elements(hosted)
            .filter { $0.identifier?.hasSuffix("\(list.prefix).Row") == true }
            .sorted { $0.frame.maxY > $1.frame.maxY }
    }

    @Test("+ and − sit inside the list's own box, right under its last row", arguments: EditableList.allCases)
    func barInsideTheBox(_ list: EditableList) async throws {
        let hosted = try await host(list, words: ["alpha", "beta"])
        let listed = rows(list, in: hosted)
        try #require(listed.count == 2, "\(list.prefix) shows \(listed.count) rows")
        let add = try #require(element(list.addSuffix, in: hosted), "\(list.prefix) has no +")
        let remove = try #require(element("\(list.prefix).Button.Remove", in: hosted), "\(list.prefix) has no −")
        let last = listed[1].frame
        let rowGap = listed[0].frame.minY - last.maxY
        let barGap = last.minY - add.frame.maxY
        #expect(add.frame.maxY <= last.minY, "\(list.prefix): + is not under the last row")
        #expect(barGap <= rowGap + 8, "\(list.prefix): + sits \(barGap) pt under the last row, rows are \(rowGap) pt apart")
        #expect(abs(add.frame.midY - remove.frame.midY) < 4, "\(list.prefix): + and − are on different lines")
        #expect(remove.frame.minX > add.frame.maxX, "\(list.prefix): − is not beside +")
        #expect(add.frame.minX - last.minX < 12, "\(list.prefix): + is not at the list's leading edge")
        await hosted.close()
    }

    @Test("− is off until a row is chosen, then removes that rule and only that one",
          arguments: EditableList.allCases.filter { $0 != .prompts })
    func removeTakesTheSelectedRule(_ list: EditableList) async throws {
        let hosted = try await host(list, words: ["alpha", "beta"])
        let before = await list.names(hosted.model)
        let remove = try #require(element("\(list.prefix).Button.Remove", in: hosted))
        #expect(remove.isEnabled == false, "\(list.prefix): − is on with nothing chosen")

        #expect(HostedAccessibility.press(endingWith: "\(list.prefix).Row", in: hosted.window.host))
        let chosen = await waitUntil { element("\(list.prefix).Button.Remove", in: hosted)?.isEnabled == true }
        #expect(chosen, "\(list.prefix): choosing a row didn't turn − on")
        let selected = rows(list, in: hosted).filter(\.isSelected)
        #expect(selected.count == 1, "\(list.prefix): \(selected.count) rows read as selected")

        #expect(HostedAccessibility.press(endingWith: "\(list.prefix).Button.Remove", in: hosted.window.host))
        let removed = await waitUntil { await list.names(hosted.model).count == 1 }
        #expect(removed)
        let after = await list.names(hosted.model)
        #expect(after == Array(before.dropFirst()), "\(list.prefix): left \(after) of \(before)")
        let off = await waitUntil { element("\(list.prefix).Button.Remove", in: hosted)?.isEnabled == false }
        #expect(off, "\(list.prefix): − stays on after the rule went")
        await hosted.close()
    }

    private enum Key {
        case up, down, delete, tab, backTab

        var code: UInt16 {
            switch self {
            case .up: 126
            case .down: 125
            case .delete: 51
            case .tab, .backTab: 48
            }
        }

        var characters: String {
            switch self {
            case .up: String(UnicodeScalar(UInt16(NSUpArrowFunctionKey)).map(Character.init) ?? " ")
            case .down: String(UnicodeScalar(UInt16(NSDownArrowFunctionKey)).map(Character.init) ?? " ")
            case .delete: "\u{7f}"
            case .tab, .backTab: "\t"
            }
        }
    }

    /// The key as the window hands it to whatever has the keyboard.
    private func press(_ key: Key, in hosted: Hosted) async {
        let window = hosted.window.window
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: key == .backTab ? [.shift] : [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: key.characters,
            charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code
        )
        if let event { window.sendEvent(event) }
        await settle(for: .milliseconds(100))
    }

    /// True when the keyboard is on the row itself: the view that has it covers the row, not one of its controls.
    private func keyboardIsOn(_ row: CGRect, in hosted: Hosted) -> Bool {
        let window = hosted.window.window
        guard let view = window.firstResponder as? NSView, !(view is NSText), view !== hosted.window.host else { return false }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        return frame.width > row.width * 0.8 && abs(frame.midY - row.midY) < row.height / 2
    }

    private func chosen(_ list: EditableList, in hosted: Hosted) -> [Bool] {
        rows(list, in: hosted).map(\.isSelected)
    }

    private func button(_ title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { self.button(title, in: $0) }.first
    }

    @Test("in a row's field ⌫ and ↑ edit the text; Shift-Tab then ⌫ removes that row and only that one",
          arguments: Pane.allCases)
    func keyboardRemovesTheRowBeingEdited(_ pane: Pane) async throws {
        let list = pane.list
        let hosted = try await host(list, words: ["alpha", "beta", "gamma"])
        let fields = elements(hosted)
            .filter { $0.identifier?.hasSuffix(pane.firstField) == true }
            .sorted { $0.frame.maxY > $1.frame.maxY }
        try #require(fields.count == 3, "\(pane.prefix) shows \(fields.count) fields")
        let found = fields[1].object as? NSTextField ?? (fields[1].object as? NSCell)?.controlView as? NSTextField
        let field = try #require(found)
        #expect(hosted.window.window.makeFirstResponder(field))
        let editing = await waitUntil { chosen(list, in: hosted) == [false, true, false] }
        #expect(editing, "\(pane.prefix): the keyboard in row 2's field didn't choose row 2")

        await press(.delete, in: hosted)
        await press(.up, in: hosted)
        let cleared = await waitUntil { await list.names(hosted.model) == ["alpha", "", "gamma"] }
        let afterTyping = await list.names(hosted.model)
        #expect(cleared, "\(pane.prefix): ⌫ in the field left \(afterTyping)")
        #expect(chosen(list, in: hosted) == [false, true, false], "\(pane.prefix): ↑ in the field chose another row")

        let row = rows(list, in: hosted)[1].frame
        for _ in 0..<3 where !keyboardIsOn(row, in: hosted) {
            await press(.backTab, in: hosted)
        }
        let responder = String(describing: hosted.window.window.firstResponder)
        #expect(keyboardIsOn(row, in: hosted), "\(pane.prefix): Shift-Tab never reached row 2, the keyboard is on \(responder)")
        await press(.delete, in: hosted)
        let removed = await waitUntil { await list.names(hosted.model) == ["alpha", "gamma"] }
        let left = await list.names(hosted.model)
        #expect(removed, "\(pane.prefix): left \(left)")
        await hosted.close()
    }

    @Test("Tab stops on the list once: ↓ chooses a row, ⌫ removes it, and a second ⌫ takes nothing more",
          arguments: EditableList.allCases)
    func keyboardChoosesAndRemoves(_ list: EditableList) async throws {
        let hosted = try await host(list, words: ["alpha", "beta", "gamma"])
        let window = hosted.window.window
        let first = try #require(rows(list, in: hosted).first).frame
        window.makeFirstResponder(nil)
        for _ in 0..<8 where !keyboardIsOn(first, in: hosted) {
            if window.firstResponder === window {
                window.selectNextKeyView(nil)
            } else {
                await press(.tab, in: hosted)
            }
        }
        let responder = String(describing: window.firstResponder)
        try #require(keyboardIsOn(first, in: hosted), "\(list.prefix): Tab never stopped on the list, the keyboard is on \(responder)")

        await press(.delete, in: hosted)
        let untouched = await list.names(hosted.model)
        #expect(untouched == ["alpha", "beta", "gamma"], "\(list.prefix): ⌫ took a rule with none chosen")
        await press(.down, in: hosted)
        #expect(chosen(list, in: hosted) == [true, false, false], "\(list.prefix): the first ↓ didn't choose the row it is on")
        await press(.down, in: hosted)
        await press(.down, in: hosted)
        await press(.up, in: hosted)
        let second = await waitUntil { chosen(list, in: hosted) == [false, true, false] }
        #expect(second, "\(list.prefix): ↓ ↓ ↑ chose \(chosen(list, in: hosted))")

        await press(.delete, in: hosted)
        if list == .prompts {
            let kept = await list.names(hosted.model)
            #expect(kept == ["alpha", "beta", "gamma"], "Prompts removed before the answer")
        }
        try await confirmIfAsked(list, in: hosted)
        let removed = await waitUntil { await list.names(hosted.model) == ["alpha", "gamma"] }
        let left = await list.names(hosted.model)
        #expect(removed, "\(list.prefix): left \(left)")
        guard list != .prompts else { return await hosted.close() }

        await press(.delete, in: hosted)
        let afterSecond = await list.names(hosted.model)
        #expect(afterSecond == ["alpha", "gamma"], "\(list.prefix): a second ⌫ took another rule")
        await press(.down, in: hosted)
        let next = await waitUntil { chosen(list, in: hosted) == [false, true] }
        #expect(next, "\(list.prefix): the keyboard left the list; ↓ chose \(chosen(list, in: hosted))")
        await hosted.close()
    }

    /// Prompts asks before it removes; the answer is Delete.
    private func confirmIfAsked(_ list: EditableList, in hosted: Hosted) async throws {
        guard list == .prompts else { return }
        let window = hosted.window.window
        let asked = await waitUntil { window.attachedSheet != nil }
        let alert = try #require(window.attachedSheet, "Prompts removed without asking")
        #expect(asked)
        let delete = try #require(alert.contentView.flatMap { button(String(localized: "Delete"), in: $0) })
        delete.performClick(nil)
        await waitUntil { window.attachedSheet == nil }
    }

    @Test("each row offers its Remove to VoiceOver and in its right-click menu, and it takes that row, not the chosen one",
          arguments: EditableList.allCases)
    func rowRemoveAction(_ list: EditableList) async throws {
        let hosted = try await host(list, words: ["alpha", "beta", "gamma"])
        #expect(HostedAccessibility.press(endingWith: "\(list.prefix).Row", in: hosted.window.host))
        let first = await waitUntil { chosen(list, in: hosted) == [true, false, false] }
        #expect(first)

        let listed = rows(list, in: hosted)
        for row in listed {
            #expect(row.actions.contains(list.removeLabel), "\(list.prefix): VoiceOver lists \(row.actions)")
        }
        #expect(HostedAccessibility.perform(list.removeLabel, on: listed[2]))
        try await confirmIfAsked(list, in: hosted)
        let third = await waitUntil { await list.names(hosted.model) == ["alpha", "beta"] }
        let afterVoiceOver = await list.names(hosted.model)
        #expect(third, "\(list.prefix): VoiceOver's Remove on the third row left \(afterVoiceOver)")

        let window = hosted.window.window
        let second = try #require(rows(list, in: hosted).last).frame
        let point = window.convertPoint(fromScreen: NSPoint(x: second.minX + 4, y: second.midY))
        let click = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let menu = try #require(hosted.window.host.menu(for: click), "\(list.prefix): a right-click on a row shows no menu")
        let index = menu.indexOfItem(withTitle: list.removeLabel)
        try #require(index >= 0, "\(list.prefix): the row's menu holds \(menu.items.map(\.title))")
        menu.performActionForItem(at: index)
        try await confirmIfAsked(list, in: hosted)
        let secondGone = await waitUntil { await list.names(hosted.model) == ["alpha"] }
        let afterMenu = await list.names(hosted.model)
        #expect(secondGone, "\(list.prefix): the menu's Remove on the second row left \(afterMenu)")
        await hosted.close()
    }

    @Test("+ adds an empty rule and chooses it, clearing a search that would hide it", arguments: Pane.allCases)
    func addChoosesTheNewRule(_ pane: Pane) async throws {
        let list = pane.list
        let words = (0..<RuleListQuery.toolbarThreshold).map { "word\($0)" }
        let hosted = try await host(list, words: words)
        let field = try #require(textField("\(pane.prefix).TextField.Search", in: hosted))
        field.stringValue = "word1"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        await waitUntil { rows(list, in: hosted).count == 1 }

        #expect(HostedAccessibility.press(endingWith: list.addSuffix, in: hosted.window.host))
        let added = await waitUntil { await list.names(hosted.model).count == words.count + 1 }
        #expect(added)
        let shown = await waitUntil { rows(list, in: hosted).count == words.count + 1 }
        #expect(shown, "\(pane.prefix): the search still hides rows after +")
        let chosen = rows(list, in: hosted).filter(\.isSelected)
        #expect(chosen.count == 1 && chosen.first?.frame == rows(list, in: hosted).last?.frame,
                "\(pane.prefix): the new rule isn't the chosen one")
        #expect(element("\(list.prefix).Button.Remove", in: hosted)?.isEnabled == true)
        await hosted.close()
    }

    @Test("Import and Export live in the list's ⋯ menu; lists with neither have no menu", arguments: EditableList.allCases)
    func moreMenu(_ list: EditableList) async throws {
        let hosted = try await host(list, words: ["alpha"])
        let ids = elements(hosted).compactMap(\.identifier)
        let more = element("\(list.prefix).Menu.More", in: hosted)
        if [.snippets, .findReplace].contains(list) {
            let menu = try #require(more, "\(list.prefix) has no ⋯ menu")
            #expect(menu.name == String(localized: "More"))
            let loose = ids.filter {
                $0.hasSuffix("Snippets.Button.Import") || $0.hasSuffix("Snippets.Button.Export")
                    || $0.hasSuffix("FindReplace.Button.ExportPack")
            }
            #expect(loose.isEmpty, "\(loose)")
        } else {
            #expect(more == nil, "\(list.prefix) has a ⋯ menu with nothing to put in it")
        }
        await hosted.close()
    }

    @Test("a long list gets the same toolbar on every pane: search, the enabled filter and sort, above the list",
          arguments: Pane.allCases)
    func longListToolbar(_ pane: Pane) async throws {
        let hosted = try await host(pane.list, words: (0..<RuleListQuery.toolbarThreshold).map { "word\($0)" })
        let search = try #require(element("\(pane.prefix).TextField.Search", in: hosted))
        let sort = try #require(element("\(pane.prefix).Menu.Sort", in: hosted))
        let filter = try #require(element("\(pane.prefix).Picker.Filter", in: hosted), "\(pane.prefix) has no enabled filter")
        let top = try #require(rows(pane.list, in: hosted).first)
        #expect(abs(search.frame.midY - sort.frame.midY) < 8, "\(pane.prefix): search and sort sit on different lines")
        #expect(abs(search.frame.midY - filter.frame.midY) < 8, "\(pane.prefix): the filter sits on its own line")
        #expect(search.frame.minY > top.frame.maxY, "\(pane.prefix): the toolbar isn't above the list")
        #expect(sort.name == String(localized: "Sort"))
        await hosted.close()
    }

    @Test("a short list has no search field or filter over it", arguments: Pane.allCases)
    func shortListHasNoToolbar(_ pane: Pane) async throws {
        let hosted = try await host(pane.list, words: ["alpha", "beta"])
        let ids = elements(hosted).compactMap(\.identifier)
        #expect(!ids.contains { $0.hasSuffix("\(pane.prefix).TextField.Search") }, "\(pane.prefix) shows search over 2 rules")
        #expect(!ids.contains { $0.hasSuffix("\(pane.prefix).Menu.Sort") }, "\(pane.prefix) shows sort over 2 rules")
        await hosted.close()
    }

    @Test("case-sensitivity is the same labelled checkbox in Corrections and Find & Replace")
    func oneCaseSensitivityControl() async throws {
        for list in [EditableList.corrections, .findReplace] {
            let hosted = try await host(list, words: ["alpha"])
            let control = try #require(element("\(list.prefix).Toggle.CaseSensitive", in: hosted))
            #expect(control.role == NSAccessibility.Role.checkBox.rawValue)
            #expect(control.name == String(localized: "Case-sensitive"), "\(list.prefix) names it \(control.name ?? "nothing")")
            await hosted.close()
        }
    }

    @Test("Find & Replace doesn't repeat its header under the list")
    func findReplaceHelperIsNotTheHeader() async throws {
        let hosted = try await host(.findReplace, words: ["alpha"])
        let words = elements(hosted).flatMap(\.words)
        #expect(!words.contains { $0.hasPrefix("Substitutions applied to every") })
        await hosted.close()
    }

    @Test("Snippets' placeholders are a note under the list, beside its other note, not a box of their own")
    func snippetPlaceholdersAreAFooter() async throws {
        let hosted = try await host(.snippets, words: ["alpha", "beta"])
        let found = elements(hosted)
        let note = try #require(found.first { $0.words.contains { $0.hasPrefix("Triggers fire on dictated text only") } })
        let placeholders = try #require(found.first { $0.words.contains { $0.hasPrefix("These placeholders expand") } })
        let add = try #require(element("Snippets.Button.Add", in: hosted))
        #expect(placeholders.frame.maxY <= note.frame.minY, "the placeholders sit above the note")
        #expect(note.frame.minY - placeholders.frame.maxY < 8, "the placeholders sit \(note.frame.minY - placeholders.frame.maxY) pt under the note")
        #expect(add.frame.minY - note.frame.maxY < 24, "the note sits \(add.frame.minY - note.frame.maxY) pt under the list")
        #expect(abs(placeholders.frame.minX - note.frame.minX) < 2, "the placeholders don't line up with the note")
        await hosted.close()
    }

    @Test("the toolbar shows from the threshold, or while it narrows the list")
    func toolbarThreshold() {
        let idle = RuleListQuery()
        #expect(idle.showsToolbar(ruleCount: RuleListQuery.toolbarThreshold - 1) == false)
        #expect(idle.showsToolbar(ruleCount: RuleListQuery.toolbarThreshold))
        #expect(RuleListQuery(search: "x").showsToolbar(ruleCount: 1))
        #expect(RuleListQuery(filter: .disabled).showsToolbar(ruleCount: 1))
        #expect(RuleListQuery(sort: .descending).showsToolbar(ruleCount: 1))
    }

    @Test("the query filters, searches every field and sorts with ties in list order")
    func arrange() {
        struct Rule: Equatable { let a: String; let b: String; let on: Bool }
        let rules = [
            Rule(a: "beta", b: "x", on: true),
            Rule(a: "Alpha", b: "y", on: false),
            Rule(a: "beta", b: "z", on: false),
            Rule(a: "gamma", b: "beta", on: true),
        ]
        let fields: (Rule) -> [String] = { [$0.a, $0.b] }
        let isOn: (Rule) -> Bool = { $0.on }
        #expect(RuleListQuery(search: "BETA").arrange(rules, fields: fields, isEnabled: isOn) == [rules[0], rules[2], rules[3]])
        #expect(RuleListQuery(filter: .disabled).arrange(rules, fields: fields, isEnabled: isOn) == [rules[1], rules[2]])
        #expect(RuleListQuery(sort: .ascending).arrange(rules, fields: fields, isEnabled: isOn) == [rules[1], rules[0], rules[2], rules[3]])
        #expect(RuleListQuery(sort: .descending).arrange(rules, fields: fields, isEnabled: isOn) == [rules[3], rules[0], rules[2], rules[1]])
        #expect(RuleListQuery(sort: .disabledFirst).arrange(rules, fields: fields, isEnabled: isOn) == [rules[1], rules[2], rules[0], rules[3]])
        #expect(RuleListQuery(sort: .enabledFirst).arrange(rules, fields: fields, isEnabled: isOn) == [rules[0], rules[3], rules[1], rules[2]])
    }
}
