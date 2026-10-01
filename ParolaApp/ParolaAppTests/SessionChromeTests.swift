import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

private let english = Locale(identifier: "en_US")

private func capturingTake(at start: Date) -> RecordingSession {
    var take = RecordingSession(
        takeID: 1, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: .startingCapture
    )
    _ = take.markCapturing(at: start)
    return take
}

/// The pixel halfway down the capsule, 6 pt in from its left end: fill, clear of the dot and the digits.
@MainActor
private func capsuleFill(_ take: RecordingSession) throws -> NSColor {
    let face = SessionCapsuleFace(take: take, showsMeter: false, isOnScreen: false, showStage: {}, stop: { _ in })
        .environment(\.colorScheme, .light)
    let renderer = ImageRenderer(content: face)
    renderer.scale = 2
    var image: CGImage?
    let appearance = try #require(NSAppearance(named: .aqua))
    appearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }
    let rendered = try #require(image)
    #expect(rendered.colorSpace?.name == CGColorSpace.sRGB)
    // The renderer draws in sRGB; the bitmap only labels it calibrated, so its components are read as they are.
    let bitmap = NSBitmapImageRep(cgImage: rendered)
    return try #require(bitmap.colorAt(x: 12, y: bitmap.pixelsHigh / 2))
}

private func matches(_ color: NSColor, _ rgba: RGBA) -> Bool {
    abs(color.redComponent - rgba.r) < 0.04 && abs(color.greenComponent - rgba.g) < 0.04
        && abs(color.blueComponent - rgba.b) < 0.04 && color.alphaComponent > 0.97
}

@MainActor
private func identifiers(in hosted: HostedWindow) -> [String] {
    HostedAccessibility.elements(in: hosted.host).compactMap(\.identifier)
}

@MainActor
private func shows(_ suffix: String, in hosted: HostedWindow) -> Bool {
    identifiers(in: hosted).contains { $0.hasSuffix(suffix) }
}

private func italianBundle() throws -> Bundle {
    let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
    return try #require(Bundle(path: path))
}

@Suite("Session chrome strings")
struct SessionChromeStringTests {
    @Test("the chrome reads in Italian")
    func italian() throws {
        let it = try italianBundle()
        #expect(String(localized: "Show Recording", bundle: it) == "Mostra registrazione")
        #expect(String(localized: "This recording was deleted. Restore it from Recently Deleted to try again.", bundle: it)
            == "Questa registrazione è stata eliminata. Ripristinala da Eliminati di recente per riprovare.")
        #expect(String(localized: "This recording was deleted.", bundle: it) == "Questa registrazione è stata eliminata.")
    }
}

@Suite("Session capsule")
struct SessionCapsuleTests {
    @Test("the capsule speaks the take's length in words")
    func spokenLabel() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var take = capturingTake(at: start)
        #expect(SessionCapsule.label(for: take, now: start.addingTimeInterval(754), locale: english)
            == "Recording, 12 minutes, 34 seconds")
        _ = take.pause(at: start.addingTimeInterval(754))
        #expect(SessionCapsule.label(for: take, now: start.addingTimeInterval(800), locale: english)
            == "Paused, 12 minutes, 34 seconds")
    }

    @Test("the capsule paints the recording red itself, rather than tinting glass")
    @MainActor
    func paintsTheRecordingRedItself() throws {
        let take = capturingTake(at: Date(timeIntervalSinceNow: -754))
        guard case .dynamic(let light, _) = DS.Color.recordingFillTheme else {
            Issue.record("the recording red is not a fixed pair")
            return
        }
        let fill = try capsuleFill(take)
        #expect(matches(fill, light), "fill \(fill)")
    }

    @Test("the meter goes below a 1000 pt window; the time and Stop stay at every width")
    func meterThreshold() {
        #expect(!SessionCapsule.showsMeter(windowWidth: MainWindowLayout.minimumWidth))
        #expect(!SessionCapsule.showsMeter(windowWidth: 999))
        #expect(SessionCapsule.showsMeter(windowWidth: 1000))
        #expect(SessionCapsule.showsMeter(windowWidth: 1180))
    }
}

@MainActor
@Suite("Session capsule on screen", .serialized)
struct SessionCapsuleHostedTests {
    private func host(_ model: AppModel, width: CGFloat) throws -> HostedWindow {
        let take = try #require(model.recording)
        // Stretched, or the window shrinks to the capsule and reads as narrow.
        let content = SessionCapsule(take: take).environment(model).frame(maxWidth: .infinity, maxHeight: .infinity)
        return HostedWindow(content, width: width, height: 120)
    }

    @Test("a narrow window drops the meter and keeps the time and Stop")
    func narrowWindowDropsTheMeterOnly() async throws {
        let audio = try tempWAV("capsule-width")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("capsule-width")
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        defer { model.endTestTake() }

        let wide = try host(model, width: 1180)
        defer { wide.close() }
        let meterShown = await waitUntil { shows("Toolbar.Meter.SessionLevel", in: wide) }
        #expect(meterShown)
        #expect(shows("Toolbar.Button.SessionTime", in: wide))
        #expect(shows("Toolbar.Button.SessionStop", in: wide))

        let narrow = try host(model, width: MainWindowLayout.minimumWidth)
        defer { narrow.close() }
        let stopShown = await waitUntil { shows("Toolbar.Button.SessionStop", in: narrow) }
        #expect(stopShown)
        await settle()
        #expect(shows("Toolbar.Button.SessionTime", in: narrow))
        #expect(!shows("Toolbar.Meter.SessionLevel", in: narrow))
    }

    @Test("the time goes back to the Stage from another page")
    func timeShowsTheStage() async throws {
        let audio = try tempWAV("capsule-time")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("capsule-time")
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        defer { model.endTestTake() }
        model.route = .transcript

        let hosted = try host(model, width: 1180)
        defer { hosted.close() }
        let shown = await waitUntil { shows("Toolbar.Button.SessionTime", in: hosted) }
        #expect(shown)
        #expect(HostedAccessibility.press(endingWith: "Toolbar.Button.SessionTime", in: hosted.host))

        #expect(model.route == .recording)
    }

    @Test("while the take starts, its Cancel ends it quietly, with nothing to report")
    func cancelWhileStarting() async throws {
        // Under the size of a take with audio in it, so a Stop here would end on "Nothing was recorded" rather than transcribe.
        let audio = try makeTakeWAV("capsule-cancel", seconds: 0.1, prefix: "parola-test")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("capsule-cancel")
        model.useStreaming = false
        model.selectedModel = "openai_whisper-tiny"
        model.takeCaptureOverride = { _ in StubSource(url: audio) }
        defer { model.cancelCurrentWork() }
        model.startRecording(source: .microphone)
        let captureUp = await waitUntil { model.takeInProgress }
        #expect(captureUp)
        #expect(model.recording?.state == .arming(.startingCapture))

        let hosted = try host(model, width: 1180)
        defer { hosted.close() }
        let shown = await waitUntil { shows("Toolbar.Button.SessionStop", in: hosted) }
        #expect(shown)
        #expect(HostedAccessibility.press(endingWith: "Toolbar.Button.SessionStop", in: hosted.host))

        let ended = await waitUntil { model.recording == nil }
        #expect(ended)
        #expect(model.exportNotice == nil)
        #expect(model.phase == .idle)
    }

    @Test("the button acts on what it drew: a Cancel drawn while the take started leaves it alone once it records")
    func cancelActsOnWhatItDrew() async throws {
        let audio = try tempWAV("capsule-drawn")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("capsule-drawn")
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        defer { model.endTestTake() }
        let takeID = try #require(model.recording?.takeID)
        let drawn = RecordingSession(
            takeID: takeID, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: .startingCapture
        )
        let face = SessionCapsuleFace(
            take: drawn, showsMeter: false, isOnScreen: false, showStage: {},
            stop: { SessionCapsule.stopOrCancel(model, cancels: $0) }
        )
        let hosted = HostedWindow(face.frame(maxWidth: .infinity, maxHeight: .infinity), width: 400, height: 120)
        defer { hosted.close() }
        let shown = await waitUntil { shows("Toolbar.Button.SessionStop", in: hosted) }
        #expect(shown)

        #expect(HostedAccessibility.press(endingWith: "Toolbar.Button.SessionStop", in: hosted.host))

        #expect(model.recording?.state == .recording, "the Cancel it showed never becomes a Stop")
    }
}

// Closures inside #expect/#require arguments can share a symbol with a later closure in the same test (Swift 6.4); bind waits first.
extension TranscriberMockSuites {
    @MainActor
    @Suite("Session capsule stops the take", .serialized)
    struct SessionCapsuleStopTests {
        @Test("Stop on a recording take stops it, and the take lands")
        func stopLandsTheTake() async throws {
            let audio = try makeTakeWAV("capsule-stop", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "stopped from the toolbar")])
                let model = makeRecordingModel("capsule-stop")
                model.useStreaming = false
                model.installTestTake(source: .microphone, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -1))

                SessionCapsule.stopOrCancel(model, cancels: false)

                let stopping = model.recording?.isCapturing == false
                #expect(stopping)
                let landed = await landedEntry(model, timeoutMs: 30_000)
                #expect(landed != nil)
            }
        }
    }
}

@MainActor
@Suite("Sidebar Recording row", .serialized)
struct SidebarRecordingRowTests {
    @Test("the row draws with no model: a late cell shows nothing and doesn't trap")
    func drawsWithNoModel() {
        let hosted = HostedWindow(SidebarRecordingRow(isSelected: true).frame(width: 240), width: 240, height: 80)
        defer { hosted.close() }
        #expect(!shows("Row.Recording", in: hosted))
    }

    @Test("a running take puts a Recording row first, and it leads back to the Stage")
    func rowLeadsBackToTheStage() async throws {
        let audio = try tempWAV("sidebar-row")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("sidebar-row")
        await model.libraryRefreshTask?.value
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        model.route = .transcript
        let sidebar = HostedWindow(LibrarySidebar().environment(model), width: 240, height: 600)
        defer { sidebar.close() }

        let rowShown = await waitUntil { sidebar.row(identifiedBy: "Sidebar.Row.Recording") != nil }
        #expect(rowShown)
        let recordingRow = try #require(sidebar.row(identifiedBy: "Sidebar.Row.Recording"))
        let libraryRow = try #require(sidebar.row(identifiedBy: "Sidebar.Row.Library"))
        #expect(recordingRow < libraryRow)
        #expect(HostedAccessibility.press(endingWith: "Sidebar.Row.Recording", in: sidebar.host))
        #expect(model.route == .recording)
        let outline = try #require(sidebar.table)
        await settle()
        #expect(outline.selectedRow == -1, "the Recording row lights itself; no native row is lit on the Stage")

        model.endTestTake()
        let gone = await waitUntil { sidebar.row(identifiedBy: "Sidebar.Row.Recording") == nil }
        #expect(gone)
    }
}

@MainActor
private func reportedWindow(_ model: AppModel) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: -12_000, y: -12_000, width: 240, height: 120),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: true
    )
    window.isReleasedWhenClosed = false
    window.title = MainWindowTitle.resting
    window.contentView = NSHostingView(rootView: Color.clear.background(MainWindowReporter(model: model)))
    window.contentView?.layoutSubtreeIfNeeded()
    return window
}

@MainActor
@Suite("Main window title", .serialized)
struct MainWindowTitleTests {
    @Test("the window reads Recording while a take runs, and Parola again once it ends")
    func titleFollowsTheTake() async throws {
        let audio = try tempWAV("window-title")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("window-title")
        let window = reportedWindow(model)
        defer { window.close() }
        #expect(window.title == "Parola")

        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        let named = await waitUntil { window.title == "Recording — Parola" }
        #expect(named)
        #expect(model.pauseTake())
        await settle()
        #expect(window.title == "Recording — Parola", "a paused take still runs")

        model.endTestTake()
        let rested = await waitUntil { window.title == "Parola" }
        #expect(rested)
    }

    @Test("a window opened during a take is named for it at once")
    func windowOpenedMidTake() throws {
        let audio = try tempWAV("window-title-reopen")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("window-title-reopen")
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        defer { model.endTestTake() }

        let window = reportedWindow(model)
        defer { window.close() }

        #expect(window.title == "Recording — Parola")
    }

    @Test("the take's title trips no window filter: not the Mini Player's, not Settings', in either language")
    func titleTripsNoFilter() throws {
        let it = try italianBundle()
        for title in [MainWindowTitle.title(takeRunning: true), MainWindowTitle.title(takeRunning: true, bundle: it)] {
            #expect(!title.contains("Mini"))
            #expect(!SettingsWindowClassifier.isSettings(identifier: nil, title: title, isMainWindow: false, isTitled: true))
        }
        #expect(MainWindowTitle.title(takeRunning: true, bundle: it) == "Registrazione — Parola")
        #expect(MainWindowTitle.title(takeRunning: false, bundle: it) == "Parola")
    }
}

@MainActor
private final class SwiftUIStandIn: NSObject, NSWindowDelegate {
    var allowsClose = true
    var askedToClose = 0
    var resizes = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        askedToClose += 1
        return allowsClose
    }

    func windowDidResize(_ notification: Notification) {
        resizes += 1
    }
}

/// Titled and closable, far off screen, kept after it closes so a test can read it back.
@MainActor
private func closableWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: -12_000, y: -12_000, width: 400, height: 300),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    return window
}

@Suite("Closing the window during a take")
struct MainWindowCloseDecisionTests {
    @Test("closing asks from the count-in until Stop; never without a take, nor once it finishes")
    func asksWhileTheTakeCanEnd() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(!MainWindowClose.asks(take: nil))
        var take = RecordingSession(
            takeID: 1, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: .countIn(remaining: 3)
        )
        #expect(MainWindowClose.asks(take: take))
        _ = take.arm(.startingCapture)
        #expect(MainWindowClose.asks(take: take))
        _ = take.markCapturing(at: start)
        #expect(MainWindowClose.asks(take: take))
        _ = take.pause(at: start.addingTimeInterval(5))
        #expect(MainWindowClose.asks(take: take))
        _ = take.resume(at: start.addingTimeInterval(6))
        _ = take.finish(at: start.addingTimeInterval(9))
        #expect(!MainWindowClose.asks(take: take))
        _ = take.transcribing(progress: nil)
        #expect(!MainWindowClose.asks(take: take))
        take.fail("boom")
        #expect(!MainWindowClose.asks(take: take))
    }
}

@MainActor
@Suite("Closing the window during a take, answered", .serialized)
struct MainWindowCloseAnswerTests {
    @Test("Keep Recording keeps the window and the take")
    func keepRecording() async throws {
        let audio = try tempWAV("close-keep")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("close-keep")
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        defer { model.endTestTake() }
        var closed = 0

        await MainWindowClose.resolve(.keepRecording, model: model, confirmDiscard: { true }, close: { closed += 1 })

        #expect(closed == 0)
        #expect(model.recording?.state == .recording)
    }

    @Test("Discard… asks again; a refusal keeps the window and the take, a yes discards and closes")
    func discardAsksAgain() async throws {
        let audio = try tempWAV("close-discard")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("close-discard")
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        defer { model.endTestTake() }
        var confirmations = 0
        var closed = 0

        await MainWindowClose.resolve(.discard, model: model, confirmDiscard: { confirmations += 1; return false }, close: { closed += 1 })
        #expect(confirmations == 1)
        #expect(closed == 0)
        #expect(model.recording?.state == .recording)

        await MainWindowClose.resolve(.discard, model: model, confirmDiscard: { confirmations += 1; return true }, close: { closed += 1 })
        #expect(confirmations == 2)
        #expect(closed == 1)
        #expect(model.recording == nil)
        let saved = await model.library.list()
        #expect(saved.isEmpty)
    }

    @Test("during a take the window asks before it closes, and Keep Recording leaves it open")
    func windowAsksFirst() throws {
        let audio = try tempWAV("close-guard")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("close-guard")
        let window = closableWindow()
        defer { window.close() }
        model.mainWindow = window
        var asked = 0
        MainWindowCloseGuard.install(on: window, model: model, ask: { asked += 1; return .keepRecording }, confirmDiscard: { false })
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        defer { model.endTestTake() }

        window.performClose(nil)

        #expect(asked == 1)
        #expect(window.isVisible)
        #expect(model.recording?.state == .recording)
    }

    @Test("with a text field focused, ⌘W's close still asks first")
    func focusedFieldStillAsks() throws {
        let audio = try tempWAV("close-field")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("close-field")
        let window = closableWindow()
        defer { window.close() }
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        window.contentView?.addSubview(field)
        model.mainWindow = window
        var asked = 0
        MainWindowCloseGuard.install(on: window, model: model, ask: { asked += 1; return .keepRecording }, confirmDiscard: { false })
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        defer { model.endTestTake() }
        #expect(window.makeFirstResponder(field))

        let responder = try #require(window.firstResponder)
        #expect(responder.tryToPerform(#selector(NSWindow.performClose(_:)), with: nil))

        #expect(asked == 1)
        #expect(window.isVisible)
    }

    @Test("with a sheet up, a close can't get past the sheet: the window stays and the take records on")
    func sheetKeepsTheWindow() throws {
        let audio = try tempWAV("close-sheet")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("close-sheet")
        let window = closableWindow()
        defer { window.close() }
        model.mainWindow = window
        MainWindowCloseGuard.install(on: window, model: model, ask: { .keepRecording }, confirmDiscard: { false })
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        defer { model.endTestTake() }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet)
        defer { window.endSheet(sheet) }

        window.performClose(nil)
        sheet.performClose(nil)

        #expect(window.isVisible)
        #expect(model.recording?.state == .recording)
    }

    @Test("with no take, the close is SwiftUI's own delegate's to answer, and other calls reach it too")
    func passesThroughWithoutATake() throws {
        let model = makeRecordingModel("close-pass")
        let window = closableWindow()
        defer { window.close() }
        let swiftUI = SwiftUIStandIn()
        window.delegate = swiftUI
        model.mainWindow = window
        var asked = 0
        MainWindowCloseGuard.install(on: window, model: model, ask: { asked += 1; return .keepRecording }, confirmDiscard: { false })

        swiftUI.allowsClose = false
        window.performClose(nil)
        #expect(swiftUI.askedToClose == 1)
        #expect(window.isVisible)

        window.setFrame(NSRect(x: -12_000, y: -12_000, width: 500, height: 320), display: false)
        #expect(swiftUI.resizes == 1)

        swiftUI.allowsClose = true
        window.performClose(nil)
        #expect(swiftUI.askedToClose == 2)
        #expect(!window.isVisible)
        #expect(asked == 0)
    }

    @Test("the main window reporter puts the question in front of the window's own delegate, once")
    func reporterInstallsTheGuard() {
        let model = makeRecordingModel("close-reporter")
        let window = reportedWindow(model)
        defer { window.close() }
        let installed = window.delegate as? MainWindowCloseGuard
        #expect(installed != nil)
        #expect(MainWindowCloseGuard.install(on: window, model: model) === installed)
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Closing the window during a take, saved", .serialized)
    struct MainWindowCloseSaveTests {
        @Test("Stop and Save stops the take and closes the window only once the take's audio is safe")
        func stopAndSaveClosesOnceSafe() async throws {
            let audio = try makeTakeWAV("close-save", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "saved before the window went")])
                let model = makeRecordingModel("close-save")
                model.useStreaming = false
                model.installTestTake(source: .microphone, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -1))
                var closedWhileRunning: Bool?

                await MainWindowClose.resolve(.stopAndSave, model: model, confirmDiscard: { false }, close: {
                    closedWhileRunning = model.takeIsRunning
                })

                #expect(closedWhileRunning == false)
                let landed = await landedEntry(model, timeoutMs: 30_000)
                #expect(landed != nil)
            }
        }

        @Test("answered from the window, Stop and Save closes it once the take is safe")
        func windowClosesAfterStopAndSave() async throws {
            let audio = try makeTakeWAV("close-save-window", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "the window waited")])
                let model = makeRecordingModel("close-save-window")
                model.useStreaming = false
                let window = closableWindow()
                defer { window.close() }
                model.mainWindow = window
                MainWindowCloseGuard.install(on: window, model: model, ask: { .stopAndSave }, confirmDiscard: { false })
                model.installTestTake(source: .microphone, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -1))
                var runningAtClose: Bool?
                let closing = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { _ in
                    MainActor.assumeIsolated { runningAtClose = model.takeIsRunning }
                }
                defer { NotificationCenter.default.removeObserver(closing) }

                window.performClose(nil)
                let stillOpen = window.isVisible
                #expect(stillOpen)

                let closed = await waitUntil { !window.isVisible }
                #expect(closed)
                #expect(runningAtClose == false)
                let landed = await landedEntry(model, timeoutMs: 30_000)
                #expect(landed != nil)
            }
        }
    }
}

private func appSource(_ name: String) throws -> String {
    let path = #filePath.replacingOccurrences(of: "ParolaAppTests/SessionChromeTests.swift", with: "ParolaApp/\(name).swift")
    return try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

@Suite("Recording menu")
struct RecordingMenuTests {
    @Test("⌘⏎ stops a take that can stop from anywhere but the chat composer, where it sends")
    func commandReturnOwner() {
        #expect(CommandReturn.stops(takeCanStop: true, composerFocused: false))
        #expect(!CommandReturn.stops(takeCanStop: true, composerFocused: true))
        #expect(!CommandReturn.stops(takeCanStop: false, composerFocused: false))
        #expect(!CommandReturn.stops(takeCanStop: false, composerFocused: true))
    }

    @Test("every item waits for a take: Stop and Discard… until Stop, Pause and Add Marker while it captures")
    func itemsFollowTheTake() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let none = RecordingMenuState(take: nil, showsRecording: false, composerFocused: false)
        #expect(!none.canEnd && !none.canCapture && !none.canShow && !none.stopOwnsCommandReturn)

        var take = RecordingSession(
            takeID: 1, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: .countIn(remaining: 3)
        )
        let countIn = RecordingMenuState(take: take, showsRecording: true, composerFocused: false)
        #expect(countIn.canEnd && !countIn.canCapture && countIn.canShow && countIn.stopOwnsCommandReturn)

        _ = take.markCapturing(at: start)
        let recording = RecordingMenuState(take: take, showsRecording: true, composerFocused: false)
        #expect(recording.canEnd && recording.canCapture && !recording.resumes && recording.stopOwnsCommandReturn)
        let typing = RecordingMenuState(take: take, showsRecording: true, composerFocused: true)
        #expect(typing.canEnd && !typing.stopOwnsCommandReturn, "the composer keeps ⌘⏎ for Send")

        _ = take.pause(at: start.addingTimeInterval(4))
        let paused = RecordingMenuState(take: take, showsRecording: true, composerFocused: false)
        #expect(paused.canEnd && paused.canCapture && paused.resumes)

        _ = take.finish(at: start.addingTimeInterval(9))
        let finishing = RecordingMenuState(take: take, showsRecording: true, composerFocused: false)
        #expect(!finishing.canEnd && !finishing.canCapture && !finishing.stopOwnsCommandReturn)
    }

    @Test("the Stage's buttons keep no ⌘⏎ or ⌘B of their own: the Recording menu is the one source")
    func stageLeavesTheShortcutsToTheMenu() throws {
        let stage = try appSource("Views/Recording/StageControls")
        #expect(!stage.contains(#".keyboardShortcut("b", modifiers: .command)"#))
        #expect(!stage.contains(".keyboardShortcut(.return, modifiers: .command)"))
    }
}

@MainActor
@Suite("Recording menu acts on the take", .serialized)
struct RecordingMenuActionTests {
    @Test("Pause, Resume and Add Marker in the menu reach the take")
    func itemsReachTheTake() async throws {
        let audio = try tempWAV("recording-menu")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("recording-menu")
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -5))
        defer { model.endTestTake() }
        let hosted = HostedWindow(VStack { RecordingCommands(model: model) }, width: 300, height: 300)
        defer { hosted.close() }
        let shown = await waitUntil { shows("Menu.Recording.Pause", in: hosted) }
        #expect(shown)

        #expect(HostedAccessibility.press(endingWith: "Menu.Recording.Pause", in: hosted.host))
        #expect(model.recording?.isPaused == true)
        await settle()
        #expect(HostedAccessibility.press(endingWith: "Menu.Recording.Pause", in: hosted.host))
        #expect(model.recording?.state == .recording)
        #expect(HostedAccessibility.press(endingWith: "Menu.Recording.AddMarker", in: hosted.host))
        #expect(model.recording?.markers.count == 1)
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("A replaced take's notice outlives its entry", .serialized)
    struct ReplacedTakeNoticeTests {
        @Test("Retry on a notice whose saved recording was deleted points to Recently Deleted, and adds nothing")
        func retryAfterTheEntryWasDeleted() async throws {
            let fixture = try tempWAV("replaced-notice-mic")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.transcriber, .audioSource]) {
                let gate = MockTranscriberGate()
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "engine boom"), gate: gate
                ))
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                let model = makeRecordingModel("replaced-notice-gone")
                model.selectedModel = "openai_whisper-tiny"
                try FileManager.default.createDirectory(at: model.inflightRecordingsURL, withIntermediateDirectories: true)
                let older = try makeTakeWAV("older", seconds: 1, in: model.inflightRecordingsURL, prefix: "parola-mic")
                defer { try? FileManager.default.removeItem(at: older) }
                recordAndStop(model, audio: older, seconds: 2)
                let transcribing = await waitUntil { ContentRoutes.stageTranscription(for: model) != nil }
                #expect(transcribing)
                model.recordingCountInSeconds = 3
                model.startRecording(source: .microphone)
                await gate.open()

                let notice = try #require(await waitForNotice(model))
                #expect(notice.actions.map(\.title) == ["Retry", "Show"])
                let saved = try #require(await landedEntry(model))
                model.cancelRecordingCountdown()
                let released = await waitUntil { !FileManager.default.fileExists(atPath: older.path) }
                #expect(released, "the working file goes once the entry holds the audio")

                model.deleteEntry(saved.id)
                let deleted = await waitUntil { await model.library.list().isEmpty }
                #expect(deleted)
                await installMockTranscriber(segments: [(0, 1, "back from nowhere")])
                let retry = try #require(notice.actions.first)
                model.performNoticeAction(retry)

                let told = await waitUntil { model.exportNotice?.message == Self.restoreFirst }
                #expect(told)
                await settle()
                let entries = await model.library.list()
                #expect(entries.isEmpty, "nothing comes back from a recording that was deleted")
                #expect(!model.hasPendingTakeWork)
                let show = try #require(model.exportNotice?.actions.first)
                #expect(show.title == "Show Recently Deleted")
                model.performNoticeAction(show)
                #expect(model.route == .recentlyDeleted)
            }
        }

        static let restoreFirst = "This recording was deleted. Restore it from Recently Deleted to try again."

        @Test("Retry on a failed Stage whose saved recording was deleted lets go of the working file and points to Recently Deleted")
        func retryOnAStageAfterTheEntryWasDeleted() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "engine boom")
                ))
                let model = makeRecordingModel("retry-stage-deleted")
                model.selectedModel = "openai_whisper-tiny"
                try FileManager.default.createDirectory(at: model.inflightRecordingsURL, withIntermediateDirectories: true)
                let working = try makeTakeWAV("stage", seconds: 1, in: model.inflightRecordingsURL, prefix: "parola-mic")
                defer { try? FileManager.default.removeItem(at: working) }
                recordAndStop(model, audio: working, seconds: 2)
                let failedOnStage = await waitUntil {
                    if case .failed = model.recording?.state { return true }
                    return false
                }
                #expect(failedOnStage)
                let saved = try #require(await landedEntry(model))
                await waitUntil { !model.hasPendingTakeWork }
                let heldForRetry = FileManager.default.fileExists(atPath: working.path)
                #expect(heldForRetry, "a failed Stage keeps the working file for its Retry")

                model.deleteEntry(saved.id)
                let deleted = await waitUntil { await model.library.list().isEmpty }
                #expect(deleted)
                model.retryFailedTake()

                let told = await waitUntil { model.exportNotice?.message == Self.restoreFirst }
                #expect(told)
                let released = await waitUntil { !FileManager.default.fileExists(atPath: working.path) }
                #expect(released, "the deleted entry keeps the audio, so the working file goes")
                let entries = await model.library.list()
                #expect(entries.isEmpty)
            }
        }

        @Test("once the deleted recording is gone from Recently Deleted too, Retry just says it was deleted")
        func retryAfterTheEntryWasPurged() async throws {
            let model = makeRecordingModel("retry-purged")
            let entry = try await model.library.add(
                transcript: AppModel.untranscribedTranscript(of: URL(fileURLWithPath: "/tmp/purged.wav"), language: nil),
                audioSource: nil
            )
            try await model.library.purge(entry.id)
            let failure = RecordingSession.Failure(
                audioURL: URL(fileURLWithPath: "/tmp/parola-purged-working.wav"),
                save: Task { entry }, recovery: nil, title: "R", category: .transcription, source: .microphone,
                annotations: AppModel.TakeAnnotations()
            )

            model.retryTake(failure)

            let told = await waitUntil { model.exportNotice?.message == "This recording was deleted." }
            #expect(told)
            #expect(model.exportNotice?.actions.isEmpty == true)
            #expect(!model.hasPendingTakeWork)
        }
    }
}

@Suite("Sidebar Recording row, after the take stops")
struct SidebarRecordingRowStateTests {
    @Test("VoiceOver hears the time while the take runs, then that it transcribes or failed")
    func spokenValue() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var take = capturingTake(at: start)
        let at = start.addingTimeInterval(754)
        #expect(SidebarRecordingRow.spokenValue(for: take, at: at, locale: english) == "Recording, 12 minutes, 34 seconds")
        _ = take.finish(at: at)
        _ = take.transcribing(progress: nil)
        #expect(SidebarRecordingRow.spokenValue(for: take, at: at, locale: english) == "Transcribing…")
        take.fail("boom")
        #expect(SidebarRecordingRow.spokenValue(for: take, at: at, locale: english) == "Failed")
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("A failed Stage keeps a way back", .serialized)
    struct FailedStageWayBackTests {
        @Test("a take that failed on its Stage stays reachable after an older take's notice opens something else")
        func failedStageStaysReachable() async throws {
            let older = try tempWAV("way-back-older")
            let fixture = try tempWAV("way-back-mic")
            defer {
                try? FileManager.default.removeItem(at: older)
                try? FileManager.default.removeItem(at: fixture)
            }
            try await withMocksCleared([.transcriber, .audioSource]) {
                let gate = MockTranscriberGate()
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "engine boom"), gate: gate
                ))
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                let model = makeRecordingModel("way-back")
                model.selectedModel = "openai_whisper-tiny"
                recordAndStop(model, audio: older, seconds: 2)
                let transcribing = await waitUntil { ContentRoutes.stageTranscription(for: model) != nil }
                #expect(transcribing)
                #expect(model.sidebarShowsRecording, "a take transcribing on its Stage keeps the row")
                model.recordingCountInSeconds = 3
                model.startRecording(source: .microphone)
                await gate.open()
                let notice = try #require(await waitForNotice(model))
                let olderEntry = try #require(await landedEntry(model))
                model.cancelRecordingCountdown()

                model.recordingCountInSeconds = 0
                model.startRecording(source: .microphone)
                let capturing = await waitUntil { model.recording?.state == .recording }
                #expect(capturing)
                model.stopRecordingAndTranscribe()
                let failedOnStage = await waitUntil {
                    if case .failed = model.recording?.state { return true }
                    return false
                }
                #expect(failedOnStage)
                #expect(model.route == .recording)
                #expect(model.exportNotice?.id == notice.id, "a take failing on its own Stage posts no notice")
                let failedTake = try #require(model.recording?.takeID)

                let show = try #require(notice.actions.last)
                model.performNoticeAction(show)
                let opened = await waitUntil { model.selectedEntryID == olderEntry.id }
                #expect(opened)
                #expect(model.route == .transcript)

                #expect(model.sidebarShowsRecording)
                let sidebar = HostedWindow(LibrarySidebar().environment(model), width: 240, height: 600)
                defer { sidebar.close() }
                let rowShown = await waitUntil { sidebar.row(identifiedBy: "Sidebar.Row.Recording") != nil }
                #expect(rowShown)
                let pressed = HostedAccessibility.press(endingWith: "Sidebar.Row.Recording", in: sidebar.host)
                #expect(pressed)
                #expect(model.route == .recording)
                #expect(model.recording?.takeID == failedTake)
                let stillFailed: Bool
                if case .failed = model.recording?.state { stillFailed = true } else { stillFailed = false }
                #expect(stillFailed)
                await waitUntil { !model.hasPendingTakeWork }
            }
        }
    }
}

@MainActor
private func allViews(in root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap { allViews(in: $0) }
}

/// The app's own main menu, as AppKit holds it.
@MainActor
private enum AppMenu {
    static func recording() throws -> NSMenu {
        let title = String(localized: "Recording")
        let item = NSApp.mainMenu?.items.first { $0.title == title }
        return try #require(item?.submenu)
    }

    /// SwiftUI fills its menus only when its delegate is asked, as AppKit asks when the menu opens; a read here asks the same way.
    static func refreshed(_ title: String) throws -> NSMenuItem {
        let menu = try recording()
        menu.delegate?.menuNeedsUpdate?(menu)
        let localized = String(localized: String.LocalizationValue(title))
        let item = menu.items.first { $0.title == localized }
        return try #require(item)
    }

    /// The item's key equivalent when it is held with ⌘ alone; "" when it holds none.
    static func shortcut(of title: String) -> String? {
        guard let item = try? refreshed(title) else { return nil }
        guard !item.keyEquivalent.isEmpty else { return "" }
        return item.keyEquivalentModifierMask == .command ? item.keyEquivalent : "\(item.keyEquivalentModifierMask.rawValue)+\(item.keyEquivalent)"
    }

    static func commandReturn(in window: NSWindow) throws -> NSEvent {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        )
        return try #require(event)
    }
}

/// The test host's own model as a test found it, put back however the test ends.
@MainActor
private struct HostModelState {
    let showsStatusItem: Bool
    let showsPill: Bool
    let route: AppModel.Route
    let paneMode: AppModel.TranscriptPaneMode

    init(_ host: AppModel) {
        showsStatusItem = host.showRecordingStatusItem
        showsPill = host.showRecordingPill
        route = host.route
        paneMode = host.transcriptPaneMode
    }

    func restore(_ host: AppModel) {
        if host.takeIsRunning { host.endTestTake() } else { host.forgetTakeSession() }
        host.chatComposerHasFocus = false
        host.transcript = nil
        host.phase = .idle
        host.route = route
        host.transcriptPaneMode = paneMode
        host.showRecordingStatusItem = showsStatusItem
        host.showRecordingPill = showsPill
    }
}

/// Every chat in the body answers from a stand-in model, under the store's lease so no other suite installs over it.
@MainActor
private func withChatModel(_ body: @MainActor () async throws -> Void) async throws {
    try await MockLanguageModelStore.shared.withLease {
        await MockLanguageModelStore.shared.install(provider: nil, response: MockLanguageModelResponse(text: "Yes, Friday."))
        do {
            try await body()
            await MockLanguageModelStore.shared.clear()
        } catch {
            await MockLanguageModelStore.shared.clear()
            throw error
        }
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("⌘⏎ in the app's own menu and main window", .serialized)
    struct CommandReturnOwnershipTests {
        private func composer(in window: NSWindow) -> NSTextField? {
            let placeholder = String(localized: "Ask about this transcript…")
            let fields = allViews(in: window.contentView ?? NSView()).compactMap { $0 as? NSTextField }
            return fields.first { $0.placeholderString == placeholder }
        }

        /// Types into the field the way the keyboard does, which puts the window's field editor on it.
        private func enter(_ text: String, into field: NSTextField, in window: NSWindow) -> Bool {
            guard window.makeFirstResponder(field), let editor = window.firstResponder as? NSTextView else { return false }
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            return true
        }

        @Test("Stop holds ⌘⏎ during a take, gives it to Send while the chat composer has the keyboard, and takes it back after")
        func commandReturnOwnership() async throws {
            let host = try #require(AppDelegate.launchModel)
            let window = try #require(host.mainWindow)
            let audio = try makeTakeWAV("command-return", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            let found = HostModelState(host)
            host.showRecordingStatusItem = false
            host.showRecordingPill = false
            defer { found.restore(host) }
            let commandReturn = try AppMenu.commandReturn(in: window)
            let mainMenu = try #require(NSApp.mainMenu)

            try await withMocksCleared(.transcriber) {
                try await withChatModel {
                    await installMockTranscriber(segments: [(0, 1, "stopped from the menu")])
                    let idleStop = AppMenu.shortcut(of: "Stop Recording")
                    #expect(idleStop == "", "with no take nothing holds ⌘⏎")
                    let marker = AppMenu.shortcut(of: "Add Marker")
                    #expect(marker == "b")

                    host.transcript = Transcript(
                        segments: [TranscriptSegment(id: 0, start: 0, end: 4, text: "we ship the patch on Friday")],
                        language: "en", modelName: "stub"
                    )
                    host.phase = .ready
                    host.installTestTake(source: .microphone, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -1))
                    host.route = .transcript
                    host.setTranscriptPaneMode(.chat)
                    let composerShown = await waitUntil(timeoutMs: 10_000) { composer(in: window) != nil }
                    #expect(composerShown)
                    let field = try #require(composer(in: window))
                    let stopHolds = await waitUntil { AppMenu.shortcut(of: "Stop Recording") == "\r" }
                    #expect(stopHolds, "a take gives ⌘⏎ to Stop while the composer doesn't have the keyboard")

                    #expect(enter("Is Friday still the date?", into: field, in: window))
                    let focused = await waitUntil { host.chatComposerHasFocus }
                    #expect(focused)
                    let stopLetGo = await waitUntil { AppMenu.shortcut(of: "Stop Recording") == "" }
                    #expect(stopLetGo, "the menu gives ⌘⏎ up while the composer has the keyboard")
                    let menuTookIt = mainMenu.performKeyEquivalent(with: commandReturn)
                    #expect(!menuTookIt)
                    let recordingWhileTyping = host.recording?.state == .recording
                    #expect(recordingWhileTyping)
                    let sendTookIt = window.performKeyEquivalent(with: commandReturn)
                    #expect(sendTookIt, "Send holds ⌘⏎ in the composer")
                    let sent = await waitUntil { field.stringValue.isEmpty }
                    #expect(sent)
                    let recordingAfterSend = host.recording?.state == .recording
                    #expect(recordingAfterSend)

                    #expect(enter("and the venue?", into: field, in: window))
                    #expect(window.makeFirstResponder(nil))
                    let left = await waitUntil { !host.chatComposerHasFocus }
                    #expect(left)
                    let stopBack = await waitUntil { AppMenu.shortcut(of: "Stop Recording") == "\r" }
                    #expect(stopBack, "leaving the composer gives ⌘⏎ back to Stop")
                    let sendKeptIt = window.performKeyEquivalent(with: commandReturn)
                    #expect(!sendKeptIt, "Send lets go of ⌘⏎ once the composer loses the keyboard")
                    #expect(field.stringValue == "and the venue?")
                    let stopped = mainMenu.performKeyEquivalent(with: commandReturn)
                    #expect(stopped)
                    let stopping = host.recording?.isCapturing == false
                    #expect(stopping, "⌘⏎ through the app's own menu stops the take")
                    let landed = await landedEntry(host, timeoutMs: 30_000)
                    #expect(landed != nil)
                    await waitUntil { !host.hasPendingTakeWork }
                    if let landed { try await host.library.purge(landed.id) }
                }
            }
        }
    }
}
