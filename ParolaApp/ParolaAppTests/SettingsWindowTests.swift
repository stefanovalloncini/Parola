import AppKit
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Settings window", .serialized)
struct SettingsWindowTests {
    private func withIsolatedDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let previous = DefaultsStore.current
        let suite = temporaryDefaults("test-settings-window-")
        DefaultsStore.current = suite
        defer { DefaultsStore.current = previous }
        try await body(suite)
    }

    private func makeModel(_ defaults: UserDefaults) -> AppModel {
        AppModel(bootstrap: AppBootstrap(
            mode: .test, library: makeTempLibraryURL("settings-window"), defaultsOverride: defaults,
            sideEffects: [], filePicker: TestFilePicker(), clock: ContinuousClock(),
            enabledFeaturesOverride: Set(ParolaFeature.allCases)
        ))
    }

    private func hostWindow(_ model: AppModel) -> HostedWindow {
        HostedWindow(
            SettingsView().environment(model).environment(LiveCaptionsController(showsPanel: false)),
            width: 900, height: 1400, toolbar: true
        )
    }

    /// The key as the window hands it to whatever has the keyboard.
    private func press(_ characters: String, code: UInt16, in hosted: HostedWindow) async {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: hosted.window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        )
        if let event { hosted.window.sendEvent(event) }
        await settle(for: .milliseconds(60))
    }

    private func views(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

    private func sidebarRoutes(in hosted: HostedWindow) -> [String] {
        let prefix = "Sidebar.Button."
        return HostedAccessibility.elements(in: hosted.host).compactMap { element in
            guard let id = element.identifier, let range = id.range(of: prefix) else { return nil }
            return String(id[range.upperBound...])
        }
    }

    @Test("the window takes the pane's name as its title and the summary as its subtitle, with no Back or Forward")
    func titleFollowsThePane() async {
        await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            let hosted = hostWindow(model)
            defer { hosted.close() }
            let titled = await waitUntil { hosted.window.title == SettingsRoute.general.label }
            #expect(titled, "title \(hosted.window.title)")
            #expect(hosted.window.subtitle == SettingsRoute.general.summary)

            model.settingsPane = SettingsRoute.dictation.rawValue
            let switched = await waitUntil { hosted.window.title == SettingsRoute.dictation.label }
            #expect(switched, "title \(hosted.window.title)")
            #expect(hosted.window.subtitle == SettingsRoute.dictation.summary)

            let items = hosted.window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
            let navigation = items.filter {
                $0.localizedCaseInsensitiveContains("back") || $0.localizedCaseInsensitiveContains("forward")
            }
            #expect(navigation.isEmpty, "\(items)")
        }
    }

    @Test("the window keeps the sidebar toggle, so it has a toolbar that stacks the title over the summary")
    func sidebarToggleGivesTheWindowAToolbar() async {
        await withIsolatedDefaults { defaults in
            let hosted = hostWindow(makeModel(defaults))
            defer { hosted.close() }
            let toggled = await waitUntil {
                let items = hosted.window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
                return items.contains { $0.localizedCaseInsensitiveContains("toggleSidebar") }
            }
            let items = hosted.window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
            #expect(toggled, "\(items)")
            #expect(hosted.window.toolbar?.isVisible == true)
        }
    }

    @Test("the sidebar opens at its own width, never under its 200 pt minimum")
    func sidebarWidth() async throws {
        try await withIsolatedDefaults { defaults in
            let hosted = hostWindow(makeModel(defaults))
            defer { hosted.close() }
            let frameView = try #require(hosted.window.contentView?.superview)
            let split = views(in: frameView).compactMap { $0 as? NSSplitView }.first
            let splitView = try #require(split)
            let laidOut = await waitUntil { (splitView.arrangedSubviews.first?.frame.width ?? 0) >= 200 }
            let width = splitView.arrangedSubviews.first?.frame.width ?? 0
            #expect(laidOut, "the sidebar is \(width) pt wide")
            #expect(width <= 280, "the sidebar is \(width) pt wide")
        }
    }

    @Test("the window keeps its 880 by 600 minimum")
    func minimumSize() async {
        await withIsolatedDefaults { defaults in
            let controller = NSHostingController(rootView: SettingsView().environment(makeModel(defaults)))
            let smallest = controller.sizeThatFits(in: CGSize(width: 10, height: 10))
            #expect(smallest.width == 880, "\(smallest)")
            #expect(smallest.height == 600, "\(smallest)")
        }
    }

    @Test("typing in the sidebar's search field narrows the list, and clearing it brings every pane back")
    func searchFieldFiltersTheSidebar() async throws {
        try await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            let hosted = hostWindow(model)
            defer { hosted.close() }
            let all = SettingsSidebarCatalog.visibleGroups(features: model.features, search: "").flatMap(\.routes)
            let listed = await waitUntil { sidebarRoutes(in: hosted).count == all.count }
            #expect(listed, "\(sidebarRoutes(in: hosted))")

            let frameView = try #require(hosted.window.contentView?.superview)
            let searchField = views(in: frameView).compactMap { $0 as? NSSearchField }.first
            let field = try #require(searchField)
            #expect(field.placeholderString == String(localized: "Search Settings…"))

            type("mic", into: field)
            let expected = SettingsSidebarCatalog.visibleGroups(features: model.features, search: "mic")
                .flatMap(\.routes).map(\.rawValue)
            #expect(expected == ["shortcuts", "microphone", "recordMeetings"])
            let narrowed = await waitUntil { sidebarRoutes(in: hosted) == expected }
            #expect(narrowed, "\(sidebarRoutes(in: hosted))")

            type("", into: field)
            let restored = await waitUntil { sidebarRoutes(in: hosted).count == all.count }
            #expect(restored, "\(sidebarRoutes(in: hosted))")
        }
    }

    @Test("the sidebar takes the arrow keys and type-select, and the pane follows")
    func sidebarKeyboard() async throws {
        try await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            let hosted = hostWindow(model)
            defer { hosted.close() }
            let sidebar = views(in: hosted.host).lazy.compactMap { $0 as? NSTableView }.first
            let table = try #require(sidebar, "no sidebar list")
            #expect(hosted.window.makeFirstResponder(table))
            let onGeneral = await waitUntil { model.settingsPane == SettingsRoute.general.rawValue }
            #expect(onGeneral, "opened on \(model.settingsPane)")

            let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey)).map(Character.init) ?? " ")
            await press(down, code: 125, in: hosted)
            let moved = await waitUntil { model.settingsPane == SettingsRoute.customization.rawValue }
            #expect(moved, "↓ from General chose \(model.settingsPane)")

            await press("l", code: 37, in: hosted)
            await press("o", code: 31, in: hosted)
            let typed = await waitUntil { model.settingsPane == SettingsRoute.localModels.rawValue }
            #expect(typed, "typing “lo” chose \(model.settingsPane)")
        }
    }

    @Test("sidebar group headers are title case, each with its Italian")
    func groupHeaders() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        for group in SettingsSidebarCatalog.all {
            let english = String(localized: String.LocalizationValue(group.titleKey))
            #expect(english != group.titleKey, "\(group.titleKey) has no English")
            #expect(english == "AI" || english != english.uppercased(), "\(english)")
            let translated = italian.localizedString(forKey: group.titleKey, value: "MISSING", table: nil)
            #expect(translated != "MISSING", "\(group.titleKey)")
        }
    }

    /// Panes left out open the microphone, start the updater, run yt-dlp or scan the model store as they appear.
    private static let resettableRoutes = SettingsRoute.allCases.filter {
        ![.microphone, .updates, .integrations, .localModels].contains($0)
    }

    @Test("every pane's Reset to Defaults asks first, names the pane, and Cancel keeps its settings")
    func resetAsksFirst() async throws {
        try await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            var asked = 0
            let resettable = Self.resettableRoutes.filter { route in
                route.paneScope.map { !$0.resetKeys(features: model.features).isEmpty } ?? false
            }
            for route in Self.resettableRoutes {
                let scope = try #require(route.paneScope, "\(route.rawValue)")
                guard let key = scope.resetKeys(features: model.features).first else { continue }
                defaults.set("sentinel", forKey: key)
                let hosted = HostedWindow(
                    route.pane.environment(model).environment(LiveCaptionsController(showsPanel: false)),
                    width: 900, height: 3000
                )
                defer { hosted.close() }

                let pressed = HostedAccessibility.press(endingWith: "Pane.Button.ResetToDefaults.\(scope.rawValue)", in: hosted.host)
                #expect(pressed, "\(route.rawValue) has no Reset to Defaults")
                guard pressed else { continue }
                let raised = await waitUntil { hosted.window.attachedSheet != nil }
                let alert = try #require(hosted.window.attachedSheet, "\(route.rawValue) reset without asking")
                #expect(raised)
                let words = HostedAccessibility.words(in: alert)
                #expect(words.contains(String(localized: "Reset \(scope.localizedLabel) to defaults?")), "\(words)")
                #expect(defaults.string(forKey: key) == "sentinel", "\(route.rawValue) cleared before the answer")

                let cancel = try #require(button(String(localized: "Cancel"), in: alert))
                cancel.performClick(nil)
                let closed = await waitUntil { hosted.window.attachedSheet == nil }
                #expect(closed)
                #expect(defaults.string(forKey: key) == "sentinel", "\(route.rawValue) cleared on Cancel")
                asked += 1
            }
            #expect(resettable.count > 10)
            #expect(asked == resettable.count, "\(asked) of \(resettable.map(\.rawValue)) asked")
        }
    }

    @Test("confirming Reset clears the pane's saved settings")
    func confirmingResetClears() async throws {
        try await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            let scope = try #require(SettingsRoute.translation.paneScope)
            let keys = scope.resetKeys(features: model.features)
            for key in keys { defaults.set(true, forKey: key) }
            let hosted = HostedWindow(SettingsRoute.translation.pane.environment(model), width: 900, height: 1200)
            defer { hosted.close() }

            #expect(HostedAccessibility.press(endingWith: "Pane.Button.ResetToDefaults.translation", in: hosted.host))
            let raised = await waitUntil { hosted.window.attachedSheet != nil }
            #expect(raised)
            let alert = try #require(hosted.window.attachedSheet)
            let reset = try #require(button(String(localized: "Reset"), in: alert))
            reset.performClick(nil)
            let cleared = await waitUntil { keys.allSatisfy { defaults.object(forKey: $0) == nil } }
            let left = keys.filter { defaults.object(forKey: $0) != nil }
            #expect(cleared, "\(left)")
        }
    }

    /// What a keystroke into the field ends in: its text changes and the field tells its delegate.
    private func type(_ text: String, into field: NSSearchField) {
        field.stringValue = text
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
    }

    private func button(_ title: String, in window: NSWindow) -> NSButton? {
        guard let content = window.contentView else { return nil }
        return views(in: content).compactMap { $0 as? NSButton }.first { $0.title == title }
    }
}
