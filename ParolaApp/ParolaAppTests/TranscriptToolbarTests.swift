import AppKit
import Foundation
import SwiftUI
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Transcript toolbar", .serialized)
struct TranscriptToolbarTests {
    private static let back = "Toolbar.Transcript.Button.Back"
    private static let panes = "Toolbar.Transcript.Picker.PaneMode"
    private static let format = "Toolbar.Transcript.Menu.Format"
    private static let readAloud = "Toolbar.Transcript.Button.ReadAloud"
    private static let askAI = "Toolbar.Transcript.Menu.AskAI"
    private static let share = "Toolbar.Transcript.Menu.Share"
    private static let inspector = "Toolbar.Transcript.Button.Inspector"
    private static let controls = [back, panes, format, readAloud, askAI, share, inspector]
    private static let newMenu = "Toolbar.Menu.New"

    private func withIsolatedDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let previous = DefaultsStore.current
        let suite = temporaryDefaults("test-transcript-toolbar-")
        DefaultsStore.current = suite
        defer { DefaultsStore.current = previous }
        try await body(suite)
    }

    private func makeModel(
        _ defaults: UserDefaults,
        features: Set<ParolaFeature> = Set(ParolaFeature.allCases),
        loaded: Bool = true
    ) -> AppModel {
        let model = AppModel(
            skipBootstrap: true,
            defaults: defaults,
            libraryURL: makeTempLibraryURL("transcript-toolbar"),
            features: features
        )
        model.libraryLoaded = true
        if loaded { load(model) }
        return model
    }

    private func load(_ model: AppModel) {
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 4, text: "one toolbar on a transcript")],
            language: "en",
            modelName: "stub"
        )
        model.phase = .ready
    }

    private func host(_ model: AppModel, width: CGFloat = 1180) -> HostedWindow {
        HostedWindow(ContentView().environment(model), width: width, height: MainWindowLayout.minimumHeight, toolbar: true)
    }

    private func toolbarIDs(_ hosted: HostedWindow) -> [String] {
        hosted.host.layoutSubtreeIfNeeded()
        return HostedAccessibility.elements(in: hosted.window).compactMap(\.identifier)
    }

    private func element(_ leaf: String, in hosted: HostedWindow) -> HostedAccessibility.Element? {
        HostedAccessibility.elements(in: hosted.window).first { $0.identifier?.hasSuffix(leaf) == true }
    }

    private func shows(_ leaf: String, in ids: [String]) -> Bool {
        ids.contains { $0.hasSuffix(leaf) }
    }

    @Test("the titled test window stays off every screen, through a resize, and its toolbar still reads and presses")
    func hostedWindowStaysOffScreen() async {
        await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            let hosted = host(model)
            defer { hosted.close() }
            #expect(hosted.window.isVisible)
            #expect(isOffScreen(hosted.window), "on screen at \(hosted.window.frame)")
            let drawn = await waitUntil { element(Self.back, in: hosted) != nil }
            #expect(drawn)
            #expect(isOffScreen(hosted.window), "on screen at \(hosted.window.frame)")

            hosted.window.setContentSize(NSSize(width: MainWindowLayout.minimumWidth, height: MainWindowLayout.minimumHeight))
            hosted.host.layoutSubtreeIfNeeded()
            #expect(isOffScreen(hosted.window), "on screen at \(hosted.window.frame) after a resize")
            #expect(HostedAccessibility.press(endingWith: Self.back, in: hosted.window))
            let back = await waitUntil { model.transcript == nil }
            #expect(back)
        }
    }

    private func isOffScreen(_ window: NSWindow) -> Bool {
        window.screen == nil && !NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    @Test("a transcript's controls sit in the window toolbar, and there is no second bar under it")
    func controlsLiveInTheWindowToolbar() async {
        await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            let hosted = host(model)
            defer { hosted.close() }
            let drawn = await waitUntil { shows(Self.inspector, in: toolbarIDs(hosted)) }
            #expect(drawn)
            let ids = toolbarIDs(hosted)
            for leaf in Self.controls {
                #expect(shows(leaf, in: ids), "no \(leaf)")
            }
            let content = HostedAccessibility.elements(in: hosted.host).compactMap(\.identifier)
            for leaf in Self.controls {
                #expect(!shows(leaf, in: content), "\(leaf) is in the page, not the toolbar")
            }
            let headerBar = ids.filter { $0.contains("HeaderBar") }
            #expect(headerBar.isEmpty, "still there: \(headerBar)")
        }
    }

    @Test("only a transcript on screen puts its controls in the toolbar: not the Library, Queue, Statistics or results over it")
    func onlyATranscriptGetsThem() async {
        await withIsolatedDefaults { defaults in
            let model = makeModel(defaults, loaded: false)
            let hosted = host(model)
            defer { hosted.close() }
            let bridged = await waitUntil { shows(Self.newMenu, in: toolbarIDs(hosted)) }
            #expect(bridged)
            await expectNoTranscriptControls(in: hosted, "on the library page")

            load(model)
            let arrived = await waitUntil { shows(Self.format, in: toolbarIDs(hosted)) }
            #expect(arrived)

            for route in [AppModel.Route.queue, .statistics] {
                model.route = route
                await expectNoTranscriptControls(in: hosted, "on \(route)")
                model.route = .transcript
                let back = await waitUntil { shows(Self.format, in: toolbarIDs(hosted)) }
                #expect(back, "not back from \(route)")
            }

            model.searchRanking = []
            #expect(model.isBrowsingLibrary)
            await expectNoTranscriptControls(in: hosted, "under search results over the transcript")
            model.searchRanking = nil
            let cleared = await waitUntil { shows(Self.format, in: toolbarIDs(hosted)) }
            #expect(cleared)
        }
    }

    @Test("the test-mode Settings preview over a transcript leaves the transcript's controls out")
    func settingsPreviewGetsNone() async {
        await withIsolatedDefaults { defaults in
            let model = AppModel(bootstrap: AppBootstrap(
                mode: .test,
                library: makeTempLibraryURL("transcript-toolbar"),
                defaultsOverride: defaults,
                sideEffects: [],
                filePicker: TestFilePicker(),
                enabledFeaturesOverride: Set(ParolaFeature.allCases)
            ))
            model.libraryLoaded = true
            load(model)
            let hosted = host(model)
            defer { hosted.close() }
            let arrived = await waitUntil { shows(Self.format, in: toolbarIDs(hosted)) }
            #expect(arrived)

            model.settingsRoutePreview = true
            await expectNoTranscriptControls(in: hosted, "over the Settings preview")
        }
    }

    /// Waits for every transcript control to leave a toolbar that is still there.
    private func expectNoTranscriptControls(
        in hosted: HostedWindow, _ place: String, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let gone = await waitUntil(sourceLocation: sourceLocation) {
            let ids = toolbarIDs(hosted)
            return shows(Self.newMenu, in: ids) && Self.controls.allSatisfy { !shows($0, in: ids) }
        }
        let ids = toolbarIDs(hosted)
        let left = Self.controls.filter { shows($0, in: ids) }
        #expect(gone, "\(place): toolbar \(shows(Self.newMenu, in: ids) ? "keeps \(left)" : "is gone")", sourceLocation: sourceLocation)
    }

    @Test("with AI off there is no pane switch and no Ask AI; the rest stay")
    func aiOffDropsThePaneSwitchAndAskAI() async {
        await withIsolatedDefaults { defaults in
            let model = makeModel(defaults, features: Set(ParolaFeature.allCases).subtracting([.ai]))
            let hosted = host(model)
            defer { hosted.close() }
            let drawn = await waitUntil { shows(Self.format, in: toolbarIDs(hosted)) }
            #expect(drawn)
            let ids = toolbarIDs(hosted)
            #expect(!shows(Self.panes, in: ids))
            #expect(!shows(Self.askAI, in: ids))
            for leaf in [Self.back, Self.readAloud, Self.share, Self.inspector] {
                #expect(shows(leaf, in: ids), "no \(leaf)")
            }
        }
    }

    @Test("Aa is off on Summary and Chat, which have no text to lay out")
    func formatIsOffOutsideTheTranscript() async {
        await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            let hosted = host(model)
            defer { hosted.close() }
            let drawn = await waitUntil { element(Self.format, in: hosted) != nil }
            #expect(drawn)
            #expect(element(Self.format, in: hosted)?.isEnabled == true)
            for mode in [AppModel.TranscriptPaneMode.summary, .chat] {
                model.setTranscriptPaneMode(mode)
                let off = await waitUntil { element(Self.format, in: hosted)?.isEnabled == false }
                #expect(off, "Aa still on in \(mode)")
            }
        }
    }

    @Test("Aa's Compact Text is off in Segments, which it doesn't change, and Subtitle Warnings works only there")
    func formatItemsFollowTheLayout() async {
        await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            let hosted = HostedWindow(VStack { TranscriptFormatItems() }.environment(model), width: 420, height: 320)
            defer { hosted.close() }
            @MainActor func enabled(_ leaf: String) -> Bool? {
                HostedAccessibility.elements(in: hosted.host).first { $0.identifier?.hasSuffix(leaf) == true }?.isEnabled
            }
            #expect(enabled("MenuItem.CompactText") == true)
            #expect(enabled("MenuItem.SubtitleWarnings") == false)
            #expect(enabled("MenuItem.TranslationSideBySide") == false, "no translation to show beside it")
            model.transcriptDisplayMode = .segments
            let flipped = await waitUntil { enabled("MenuItem.CompactText") == false }
            #expect(flipped)
            #expect(enabled("MenuItem.SubtitleWarnings") == true)
        }
    }

    @Test("Share starts with Export…, then the copies, then the ways to send it on")
    func shareItemsReadInOrder() {
        let model = makeModel(temporaryDefaults("test-transcript-toolbar-share-"))
        let hosted = HostedWindow(VStack(alignment: .leading) { TranscriptShareItems() }.environment(model), width: 420, height: 480)
        let elements = HostedAccessibility.elements(in: hosted.host)
        hosted.close()
        let titles = ["Export…", "Export As", "Copy Transcript", "Copy with Timestamps", "Share…", "Send via Mail…", "Print Transcript…"]
        var seen: Set<String> = []
        let order = elements
            .sorted { $0.frame.midY > $1.frame.midY }
            .compactMap { $0.name ?? Self.attributedTitle(of: $0.object) }
            .filter { titles.contains($0) && seen.insert($0).inserted }
        let copy = elements.first { $0.identifier?.hasSuffix("MenuItem.CopyTranscript") == true }
        #expect(order == titles)
        #expect(copy?.name == "Copy Transcript")
    }

    /// A menu button's title, which AppKit hands over styled.
    private static func attributedTitle(of object: NSObject) -> String? {
        guard object.responds(to: NSSelectorFromString("accessibilityTitle")) else { return nil }
        return (object.value(forKey: "accessibilityTitle") as? NSAttributedString)?.string
    }

    @Test("Back names where it goes and takes the transcript back there")
    func backReturnsToTheList() async {
        await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            let hosted = host(model)
            defer { hosted.close() }
            let drawn = await waitUntil { element(Self.back, in: hosted) != nil }
            #expect(drawn)
            #expect(element(Self.back, in: hosted)?.name == "Back to Library")
            #expect(HostedAccessibility.press(endingWith: Self.back, in: hosted.window))
            let back = await waitUntil { model.transcript == nil }
            #expect(back)
            #expect(model.isBrowsingLibrary)
        }
    }

    @Test("a hidden inspector comes back from the toolbar, at either width", arguments: [1400, 1040] as [CGFloat])
    func toolbarTogglesTheInspector(width: CGFloat) async {
        await withIsolatedDefaults { defaults in
            defaults.set(false, forKey: InspectorVisibility.preferenceKey)
            let model = makeModel(defaults)
            let hosted = host(model, width: width)
            defer { hosted.close() }
            let drawn = await waitUntil { element(Self.inspector, in: hosted) != nil }
            #expect(drawn)
            #expect(model.transcriptPaneIsNarrow == (width < 1100))
            #expect(!hasInspectorColumn(hosted.host))
            #expect(element(Self.inspector, in: hosted)?.name == "Show Inspector")

            #expect(HostedAccessibility.press(endingWith: Self.inspector, in: hosted.window))
            let shown = await waitUntil { hasInspectorColumn(hosted.host) }
            #expect(shown)
            let renamed = await waitUntil { element(Self.inspector, in: hosted)?.name == "Hide Inspector" }
            #expect(renamed)

            #expect(HostedAccessibility.press(endingWith: Self.inspector, in: hosted.window))
            let hidden = await waitUntil { !hasInspectorColumn(hosted.host) }
            #expect(hidden)
        }
    }

    private func hasInspectorColumn(_ host: NSView) -> Bool {
        host.layoutSubtreeIfNeeded()
        var found = false
        func walk(_ view: NSView) {
            for sub in view.subviews {
                let frame = sub.convert(sub.bounds, to: host)
                if abs(frame.width - MainWindowLayout.inspectorWidth) < 0.5, abs(frame.maxX - host.bounds.width) < 0.5 {
                    found = true
                }
                walk(sub)
            }
        }
        walk(host)
        return found
    }
}
