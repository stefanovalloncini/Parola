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

/// The capsule drawn at 2x, in one appearance and contrast.
@MainActor
private func renderedCapsule(
    _ take: RecordingSession, scheme: ColorScheme = .light, contrast: ColorSchemeContrast = .standard
) throws -> NSBitmapImageRep {
    let face = SessionCapsuleFace(take: take, showsMeter: false, isOnScreen: false, showStage: {}, stop: { _ in })
        .environment(\.colorScheme, scheme)
        .environment(\._colorSchemeContrast, contrast)
    let renderer = ImageRenderer(content: face)
    renderer.scale = 2
    var image: CGImage?
    let appearance = try #require(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
    appearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }
    let rendered = try #require(image)
    #expect(rendered.colorSpace?.name == CGColorSpace.sRGB)
    // The renderer draws in sRGB; the bitmap only labels it calibrated, so its components are read as they are.
    return NSBitmapImageRep(cgImage: rendered)
}

/// The pixel halfway down the capsule, `x` points in from its left end.
private func capsulePixel(_ bitmap: NSBitmapImageRep, at x: CGFloat) throws -> NSColor {
    try #require(bitmap.colorAt(x: Int(x * 2), y: bitmap.pixelsHigh / 2))
}

private enum CapsulePoint {
    static let edge: CGFloat = 0.5
    /// Clear of the dot and the digits.
    static let fill: CGFloat = 6
    static let dot: CGFloat = 18
}

private func matches(_ color: NSColor, _ rgba: RGBA) -> Bool {
    abs(color.redComponent - rgba.r) < 0.04 && abs(color.greenComponent - rgba.g) < 0.04
        && abs(color.blueComponent - rgba.b) < 0.04 && color.alphaComponent > 0.97
}

private func isRed(_ color: NSColor) -> Bool {
    color.alphaComponent > 0.5 && color.redComponent - max(color.greenComponent, color.blueComponent) > 0.3
}

/// How far a pixel stands from the window behind it, white in light and black in dark, once laid over it.
private func standOut(_ color: NSColor, in scheme: ColorScheme) -> Double {
    let page: CGFloat = scheme == .dark ? 0 : 1
    let alpha = color.alphaComponent
    let shown = [color.redComponent, color.greenComponent, color.blueComponent].map { $0 * alpha + page * (1 - alpha) }
    return Double(shown.map { abs($0 - page) }.reduce(0, +) / 3)
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

    @Test("the capsule is plain glass: only its dot is the recording red, in either appearance", arguments: [ColorScheme.light, .dark])
    @MainActor
    func onlyTheDotIsRed(scheme: ColorScheme) throws {
        guard case .dynamic(let light, let dark) = DS.Color.recordingFillTheme else {
            Issue.record("the recording red is not a fixed pair")
            return
        }
        let capsule = try renderedCapsule(capturingTake(at: Date(timeIntervalSinceNow: -754)), scheme: scheme)
        let fill = try capsulePixel(capsule, at: CapsulePoint.fill)
        let dot = try capsulePixel(capsule, at: CapsulePoint.dot)
        #expect(!isRed(fill), "fill \(fill)")
        #expect(matches(dot, scheme == .dark ? dark : light), "dot \(dot)")
    }

    @Test("a paused take's dot turns amber on the glass")
    @MainActor
    func pausedDotIsAmber() throws {
        guard case .dynamic(let amber, _) = ThemePreset.defaultPreset.palette.warning else {
            Issue.record("the warning amber is not a fixed pair")
            return
        }
        let start = Date(timeIntervalSinceNow: -754)
        var take = capturingTake(at: start)
        _ = take.pause(at: start.addingTimeInterval(754))
        let capsule = try renderedCapsule(take)
        let fill = try capsulePixel(capsule, at: CapsulePoint.fill)
        let dot = try capsulePixel(capsule, at: CapsulePoint.dot)
        #expect(!isRed(fill), "fill \(fill)")
        #expect(matches(dot, amber), "dot \(dot)")
    }

    @Test("under Increase Contrast a ring outlines the capsule's glass, in either appearance", arguments: [ColorScheme.light, .dark])
    @MainActor
    func increaseContrastRingsTheGlass(scheme: ColorScheme) throws {
        let take = capturingTake(at: Date(timeIntervalSinceNow: -754))
        let standard = try capsulePixel(renderedCapsule(take, scheme: scheme), at: CapsulePoint.edge)
        let increased = try capsulePixel(renderedCapsule(take, scheme: scheme, contrast: .increased), at: CapsulePoint.edge)
        #expect(standOut(increased, in: scheme) > standOut(standard, in: scheme) + 0.15, "standard \(standard), increased \(increased)")
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
            stop: { TakeRemote.stopOrCancel(model, cancels: $0) }
        )
        let hosted = HostedWindow(face.frame(maxWidth: .infinity, maxHeight: .infinity), width: 400, height: 120)
        defer { hosted.close() }
        let shown = await waitUntil { shows("Toolbar.Button.SessionStop", in: hosted) }
        #expect(shown)

        #expect(HostedAccessibility.press(endingWith: "Toolbar.Button.SessionStop", in: hosted.host))

        #expect(model.recording?.state == .recording, "the Cancel it showed never becomes a Stop")
    }

    @Test("VoiceOver hears the time, Stop and the level as before; paused, the meter goes, and finishing dims Stop")
    func spokenThroughPauseAndFinish() async throws {
        let audio = try tempWAV("capsule-spoken")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("capsule-spoken")
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -754))
        defer { model.endTestTake() }
        let takeID = model.recording?.takeID
        model.goHome()
        let hosted = HostedWindow(RecordControl().environment(model).frame(maxWidth: .infinity, maxHeight: .infinity), width: 1180, height: 120)
        defer { hosted.close() }
        @MainActor func element(_ suffix: String) -> HostedAccessibility.Element? {
            HostedAccessibility.elements(in: hosted.host).first { $0.identifier?.hasSuffix(suffix) == true }
        }

        let drawn = await waitUntil { element("Toolbar.Meter.SessionLevel") != nil }
        try #require(drawn)
        #expect(element("Toolbar.Button.SessionTime")?.label?.hasPrefix("Recording, 12 minutes, ") == true)
        #expect(element("Toolbar.Button.SessionStop")?.name == "Stop Recording")
        #expect(element("Toolbar.Button.SessionStop")?.isEnabled == true)
        #expect(element("Toolbar.Meter.SessionLevel")?.label == "Input level")

        model.updateSession(of: takeID) { $0.pause(at: Date()) }
        let paused = await waitUntil { element("Toolbar.Button.SessionTime")?.label?.hasPrefix("Paused, 12 minutes, ") == true }
        #expect(paused)
        #expect(element("Toolbar.Meter.SessionLevel") == nil)
        #expect(element("Toolbar.Button.SessionStop")?.isEnabled == true)

        model.updateSession(of: takeID) { $0.finish(at: Date()) }
        let dimmed = await waitUntil { element("Toolbar.Button.SessionStop")?.isEnabled == false }
        #expect(dimmed)
        #expect(element("Toolbar.Button.SessionStop")?.name == "Stop Recording")
    }
}

@MainActor
@Suite("Session capsule in the window toolbar", .serialized)
struct SessionCapsuleToolbarTests {
    private static let time = "Toolbar.Button.SessionTime"
    private static let stop = "Toolbar.Button.SessionStop"
    private static let meter = "Toolbar.Meter.SessionLevel"
    private static let record = "Toolbar.Button.Record"
    private static let newMenu = "Toolbar.Menu.New"
    private static let share = "Toolbar.Transcript.Menu.Share"
    private static let stageStop = "Stage.Button.Stop"

    private func host(_ model: AppModel, width: CGFloat = 1180) -> HostedWindow {
        HostedWindow(ContentView().environment(model), width: width, height: MainWindowLayout.minimumHeight, toolbar: true)
    }

    private func element(_ leaf: String, in hosted: HostedWindow) -> HostedAccessibility.Element? {
        hosted.host.layoutSubtreeIfNeeded()
        return HostedAccessibility.elements(in: hosted.window).first { $0.identifier?.hasSuffix(leaf) == true }
    }

    @Test("on the Stage the toolbar leaves the take to the Stage's own clock and Stop; the capsule is back once another page shows")
    func stageHidesTheCapsule() async throws {
        let audio = try tempWAV("capsule-stage")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("capsule-stage")
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -60))
        defer { model.endTestTake() }
        #expect(model.route == .recording)
        let hosted = host(model)
        defer { hosted.close() }

        let staged = await waitUntil { element(Self.stageStop, in: hosted) != nil && element(Self.newMenu, in: hosted) != nil }
        try #require(staged)
        for leaf in [Self.time, Self.stop, Self.meter, Self.record] {
            #expect(element(leaf, in: hosted) == nil, "\(leaf) on the Stage")
        }

        model.goHome()
        let back = await waitUntil { element(Self.time, in: hosted) != nil && element(Self.stop, in: hosted) != nil }
        #expect(back)
        #expect(element(Self.stageStop, in: hosted) == nil)
        #expect(element(Self.record, in: hosted) == nil)

        #expect(model.showStage())
        let hiddenAgain = await waitUntil { element(Self.time, in: hosted) == nil && element(Self.stageStop, in: hosted) != nil }
        #expect(hiddenAgain)
        #expect(element(Self.stop, in: hosted) == nil)
    }

    @Test(
        "on a transcript the capsule sits just after the transcript's controls, whole and inside the window",
        arguments: [1180, MainWindowLayout.minimumWidth]
    )
    func besideTheTranscriptControls(width: CGFloat) async throws {
        let audio = try tempWAV("capsule-transcript")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("capsule-transcript")
        model.libraryLoaded = true
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 4, text: "a take runs behind this transcript")],
            language: "en",
            modelName: "stub"
        )
        model.phase = .ready
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -60))
        defer { model.endTestTake() }
        model.route = .transcript
        #expect(model.transcriptToolbarShows)
        let hosted = host(model, width: width)
        defer { hosted.close() }

        let drawn = await waitUntil { element(Self.share, in: hosted) != nil && element(Self.stop, in: hosted) != nil }
        try #require(drawn)
        if SessionCapsule.showsMeter(windowWidth: width) {
            let metered = await waitUntil { element(Self.meter, in: hosted) != nil }
            #expect(metered)
        } else {
            await settle()
            #expect(element(Self.meter, in: hosted) == nil)
        }
        let share = try #require(element(Self.share, in: hosted)).frame
        let time = try #require(element(Self.time, in: hosted)).frame
        let stop = try #require(element(Self.stop, in: hosted)).frame
        let window = hosted.window.frame
        let gap = time.minX - share.maxX
        #expect(gap >= 0 && gap <= 32, "\(width) pt: \(gap) pt from Share (\(share)) to the capsule (\(time))")
        #expect(stop.minX >= time.maxX - 0.5, "\(width) pt: time \(time), Stop \(stop)")
        #expect(abs(stop.midY - time.midY) < 1 && abs(time.midY - share.midY) < 1, "\(width) pt: share \(share), time \(time), Stop \(stop)")
        #expect(time.minX >= window.minX && stop.maxX <= window.maxX, "\(width) pt: capsule \(time)–\(stop) outside \(window)")
        if let plus = element(Self.newMenu, in: hosted)?.frame, plus.width > 0 {
            #expect(plus.minX >= stop.maxX, "\(width) pt: + at \(plus) over Stop at \(stop)")
        }
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

                TakeRemote.stopOrCancel(model, cancels: false)

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

    @Test("an open transcript names the window, a take outranks it, and nothing open reads Parola")
    func titleNamesTheOpenTranscript() {
        #expect(MainWindowTitle.title(takeRunning: false, transcriptTitle: "Board review") == "Board review")
        #expect(MainWindowTitle.title(takeRunning: true, transcriptTitle: "Board review") == "Recording — Parola")
        #expect(MainWindowTitle.title(takeRunning: false, transcriptTitle: nil) == "Parola")
    }

    @Test("the window takes the open entry's name, and Parola again once another page shows")
    func windowFollowsTheOpenEntry() async throws {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("window-title-entry"))
        let store = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello there.")], language: "en", modelName: "stub"
        )
        let seeded = try await store.add(transcript: transcript, audioSource: nil, category: .transcription, title: "Board review")
        let window = reportedWindow(model)
        defer { window.close() }

        model.loadEntry(seeded.id)
        let named = await waitUntil { window.title == "Board review" }
        #expect(named)
        #expect(model.shownTranscriptTitle == "Board review")

        model.route = .statistics
        let rested = await waitUntil { window.title == "Parola" }
        #expect(rested)
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
    let window = OffscreenWindow(width: 400, height: 300, styleMask: [.titled, .closable, .resizable])
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    return window
}

@Suite("Closing the window during a take")
struct MainWindowCloseDecisionTests {
    @Test("while a take is still starting, the close question doesn't speak of keeping what it recorded, in English or Italian")
    func startingQuestion() throws {
        let starting = AppDelegate.closeQuestion(starting: true)
        #expect(starting.message == "A recording is starting")
        #expect(starting.detail == "Nothing has been recorded yet.")
        #expect(starting.discard == "Discard", "no second question follows, so no ellipsis")
        let recording = AppDelegate.closeQuestion(starting: false)
        #expect(recording.message == "A recording is in progress")
        #expect(recording.detail == "Stop and Save keeps what you've recorded so far in your library.")
        #expect(recording.discard == "Discard…")
        let it = try italianBundle()
        let italian = AppDelegate.closeQuestion(starting: true, bundle: it)
        #expect(italian.message == "Una registrazione sta per iniziare")
        #expect(italian.detail == "Non è ancora stato registrato nulla.")
        #expect(italian.discard == "Scarta")
        #expect(AppDelegate.closeQuestion(starting: false, bundle: it).discard == "Scarta…")
    }

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

        let takeID = try #require(model.recording?.takeID)
        await MainWindowClose.resolve(.keepRecording, about: takeID, model: model, confirmDiscard: { true }, close: { closed += 1 })

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

        let takeID = try #require(model.recording?.takeID)
        await MainWindowClose.resolve(.discard, about: takeID, model: model, confirmDiscard: { confirmations += 1; return false }, close: { closed += 1 })
        #expect(confirmations == 1)
        #expect(closed == 0)
        #expect(model.recording?.state == .recording)

        await MainWindowClose.resolve(.discard, about: takeID, model: model, confirmDiscard: { confirmations += 1; return true }, close: { closed += 1 })
        #expect(confirmations == 2)
        #expect(closed == 1)
        #expect(model.recording == nil)
        let saved = await model.library.list()
        #expect(saved.isEmpty)
    }

    @Test("during a take the window asks before it closes, and Keep Recording leaves it open")
    func windowAsksFirst() async throws {
        let audio = try tempWAV("close-guard")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("close-guard")
        let window = closableWindow()
        defer { window.close() }
        model.mainWindow = window
        var asked = 0
        var askedOn: NSWindow?
        var askedAbout: Int?
        MainWindowCloseGuard.install(
            on: window, model: model,
            ask: { closing, take in asked += 1; askedOn = closing; askedAbout = take.takeID; return .keepRecording },
            confirmDiscard: { _ in false }
        )
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        defer { model.endTestTake() }

        window.performClose(nil)

        let wasAsked = await waitUntil { asked == 1 }
        #expect(wasAsked)
        #expect(askedOn === window, "the question is a sheet on the window that is closing")
        #expect(askedAbout == model.recording?.takeID, "the question is about the take running now")
        await settle()
        #expect(window.isVisible)
        #expect(model.recording?.state == .recording)
    }

    @Test("Discard… from the window asks again on that window; a yes discards the take and closes it")
    func discardFromTheWindow() async throws {
        let audio = try tempWAV("close-discard-window")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("close-discard-window")
        let window = closableWindow()
        defer { window.close() }
        model.mainWindow = window
        var confirmedOn: NSWindow?
        MainWindowCloseGuard.install(
            on: window, model: model, ask: { _, _ in .discard }, confirmDiscard: { closing in confirmedOn = closing; return true }
        )
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        defer { model.endTestTake() }

        window.performClose(nil)

        let closed = await waitUntil { !window.isVisible }
        #expect(closed)
        #expect(confirmedOn === window)
        #expect(model.recording == nil)
        let saved = await model.library.list()
        #expect(saved.isEmpty)
    }

    @Test("with a text field focused, ⌘W's close still asks first")
    func focusedFieldStillAsks() async throws {
        let audio = try tempWAV("close-field")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("close-field")
        let window = closableWindow()
        defer { window.close() }
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        window.contentView?.addSubview(field)
        model.mainWindow = window
        var asked = 0
        MainWindowCloseGuard.install(on: window, model: model, ask: { _, _ in asked += 1; return .keepRecording }, confirmDiscard: { _ in false })
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        defer { model.endTestTake() }
        #expect(window.makeFirstResponder(field))

        let responder = try #require(window.firstResponder)
        #expect(responder.tryToPerform(#selector(NSWindow.performClose(_:)), with: nil))

        let wasAsked = await waitUntil { asked == 1 }
        #expect(wasAsked)
        #expect(window.isVisible)
    }

    @Test("with a sheet up, a close can't get past the sheet: the window stays and the take records on")
    func sheetKeepsTheWindow() async throws {
        let audio = try tempWAV("close-sheet")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("close-sheet")
        let window = closableWindow()
        defer { window.close() }
        model.mainWindow = window
        var asked = 0
        MainWindowCloseGuard.install(on: window, model: model, ask: { _, _ in asked += 1; return .keepRecording }, confirmDiscard: { _ in false })
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        defer { model.endTestTake() }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet, completionHandler: nil)
        defer { window.endSheet(sheet) }

        window.performClose(nil)
        sheet.performClose(nil)

        await settle()
        #expect(asked == 0, "AppKit refuses the close before anything is asked")
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
        MainWindowCloseGuard.install(on: window, model: model, ask: { _, _ in asked += 1; return .keepRecording }, confirmDiscard: { _ in false })

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

    @Test("the app's own window has the question in front of SwiftUI's delegate, the window's controller")
    func appWindowIsGuarded() async throws {
        let opened = await waitUntil { AppDelegate.launchModel?.mainWindow != nil }
        #expect(opened)
        let window = try #require(AppDelegate.launchModel?.mainWindow)
        let closeGuard = try #require(window.delegate as? MainWindowCloseGuard)
        let controller = try #require(window.windowController)
        #expect(closeGuard.wrapped === controller)
    }

    @Test("a take puts the question back in front of a delegate that changed since the window opened")
    func takeReinstallsTheGuard() async throws {
        let audio = try tempWAV("close-reinstall")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("close-reinstall")
        let window = reportedWindow(model)
        defer { window.close() }
        let replacement = SwiftUIStandIn()
        window.delegate = replacement

        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        defer { model.endTestTake() }

        let guarded = await waitUntil { (window.delegate as? MainWindowCloseGuard)?.wrapped === replacement }
        #expect(guarded)
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

                let takeID = try #require(model.recording?.takeID)
                await MainWindowClose.resolve(.stopAndSave, about: takeID, model: model, confirmDiscard: { false }, close: {
                    closedWhileRunning = model.takeIsRunning
                })

                #expect(closedWhileRunning == false)
                let landed = await landedEntry(model, timeoutMs: 30_000)
                #expect(landed != nil)
            }
        }

        @Test("a take that stops by itself under the close sheet is saved, not discarded, and nothing more is asked")
        func takeStopsUnderTheSheet() async throws {
            let audio = try makeTakeWAV("close-stops-itself", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "kept after all")])
                let model = makeRecordingModel("close-stops-itself")
                model.useStreaming = false
                let window = closableWindow()
                defer { window.close() }
                model.mainWindow = window
                var confirmations = 0
                var asked = 0
                MainWindowCloseGuard.install(
                    on: window, model: model,
                    ask: { _, _ in asked += 1; model.stopRecordingAndTranscribe(); return .discard },
                    confirmDiscard: { _ in confirmations += 1; return true }
                )
                model.installTestTake(source: .microphone, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -1))

                window.performClose(nil)

                let closed = await waitUntil { !window.isVisible }
                #expect(closed, "with no take running, the window closes as answered")
                #expect(asked == 1)
                #expect(confirmations == 0, "a take already on its way to the library is not asked about again")
                let landed = await landedEntry(model, timeoutMs: 30_000)
                #expect(landed != nil, "the recording that stopped by itself is kept")
            }
        }

        @Test("a take started under the close sheet is asked about in turn, and the answer about the earlier one never ends it", arguments: [
            AppModel.QuitDuringTake.stopAndSave, .discard,
        ])
        func newTakeUnderTheSheet(_ answer: AppModel.QuitDuringTake) async throws {
            let first = try makeTakeWAV("close-first-take", seconds: 1)
            let second = try makeTakeWAV("close-second-take", seconds: 1)
            defer {
                try? FileManager.default.removeItem(at: first)
                try? FileManager.default.removeItem(at: second)
            }
            try await withMocksCleared(.transcriber) {
                let model = makeRecordingModel("close-new-take")
                model.useStreaming = false
                let window = closableWindow()
                defer { window.close() }
                model.mainWindow = window
                var askedAbout: [Int] = []
                var confirmations = 0
                var newTake: Int?
                MainWindowCloseGuard.install(
                    on: window, model: model,
                    ask: { _, take in
                        askedAbout.append(take.takeID)
                        guard askedAbout.count == 1 else { return .keepRecording }
                        model.endTestTake()
                        model.installTestTake(source: .microphone, liveSource: StubSource(url: second))
                        newTake = model.recording?.takeID
                        return answer
                    },
                    confirmDiscard: { _ in confirmations += 1; return true }
                )
                model.installTestTake(source: .microphone, liveSource: StubSource(url: first), startedAt: Date(timeIntervalSinceNow: -1))
                defer { model.endTestTake() }

                window.performClose(nil)

                let askedAgain = await waitUntil { askedAbout.count == 2 }
                #expect(askedAgain, "the take still recording gets its own question")
                #expect(askedAbout.last == newTake)
                await settle()
                #expect(window.isVisible, "Keep Recording on the second question keeps the window")
                #expect(confirmations == 0)
                let stillRecording = newTake != nil && model.recording?.takeID == newTake && model.recording?.state == .recording
                #expect(stillRecording, "the new take records on")
            }
        }

        @Test("a count-in asked about, then cancelled under the sheet, leaves its id behind: the take started next is not the one the answer ends", arguments: [
            AppModel.QuitDuringTake.stopAndSave, .discard,
        ])
        func countInCancelledUnderTheSheet(_ answer: AppModel.QuitDuringTake) async throws {
            let audio = try makeTakeWAV("close-count-in", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            let model = makeRecordingModel("close-count-in")
            model.useStreaming = false
            model.selectedModel = "openai_whisper-tiny"
            model.takeCaptureOverride = { _ in StubSource(url: audio) }
            defer { await model.discardTake() }
            let window = closableWindow()
            defer { window.close() }
            model.mainWindow = window
            var askedAbout: [Int] = []
            var confirmations = 0
            var newTake: Int?
            MainWindowCloseGuard.install(
                on: window, model: model,
                ask: { _, take in
                    askedAbout.append(take.takeID)
                    guard askedAbout.count == 1 else { return .keepRecording }
                    model.cancelRecordingCountdown()
                    model.recordingCountInSeconds = 0
                    model.startRecording(source: .microphone)
                    newTake = model.recording?.takeID
                    return answer
                },
                confirmDiscard: { _ in confirmations += 1; return true }
            )
            model.recordingCountInSeconds = 3
            model.startRecording(source: .microphone)
            #expect(model.recordingCountdown == 3)
            let countIn = try #require(model.recording?.takeID)

            window.performClose(nil)

            let askedAgain = await waitUntil { askedAbout.count == 2 }
            #expect(askedAgain)
            #expect(askedAbout.first == countIn)
            #expect(newTake != nil && newTake != countIn, "the new take has an id of its own")
            #expect(askedAbout.last == newTake)
            let untouched = model.recording?.takeID == newTake && model.recording?.isRunning == true
            #expect(untouched, "the answer about the count-in neither stops nor discards the new take")
            #expect(confirmations == 0)
            #expect(window.isVisible)
        }

        @Test("Stop and Save closes the window that asked, even while another window is the main one")
        func closesTheWindowThatAsked() async throws {
            let audio = try makeTakeWAV("close-save-other", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "the right window went")])
                let model = makeRecordingModel("close-save-other")
                model.useStreaming = false
                let asking = closableWindow()
                let other = closableWindow()
                defer {
                    asking.close()
                    other.close()
                }
                MainWindowCloseGuard.install(on: asking, model: model, ask: { _, _ in .stopAndSave }, confirmDiscard: { _ in false })
                model.mainWindow = other
                model.installTestTake(source: .microphone, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -1))

                asking.performClose(nil)

                let closed = await waitUntil { !asking.isVisible }
                #expect(closed)
                let otherStays = other.isVisible
                #expect(otherStays)
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
                MainWindowCloseGuard.install(on: window, model: model, ask: { _, _ in .stopAndSave }, confirmDiscard: { _ in false })
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

    @Test("every item waits for a take: Stop until it finishes; Pause, Add Marker and Discard… while it captures")
    func itemsFollowTheTake() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let none = RecordingMenuState(take: nil, showsRecording: false, composerFocused: false)
        #expect(!none.canEnd && !none.canCapture && !none.canShow && !none.stopOwnsCommandReturn)

        var take = RecordingSession(
            takeID: 1, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: .countIn(remaining: 3)
        )
        let countIn = RecordingMenuState(take: take, showsRecording: true, composerFocused: false)
        #expect(countIn.canEnd && !countIn.canCapture && countIn.canShow && countIn.stopOwnsCommandReturn)
        #expect(!countIn.canDiscard, "nothing is recorded yet, so there is nothing to discard")

        _ = take.markCapturing(at: start)
        let recording = RecordingMenuState(take: take, showsRecording: true, composerFocused: false)
        #expect(recording.canEnd && recording.canCapture && recording.canDiscard && !recording.resumes && recording.stopOwnsCommandReturn)
        let typing = RecordingMenuState(take: take, showsRecording: true, composerFocused: true)
        #expect(typing.canEnd && !typing.stopOwnsCommandReturn, "the composer keeps ⌘⏎ for Send")

        _ = take.pause(at: start.addingTimeInterval(4))
        let paused = RecordingMenuState(take: take, showsRecording: true, composerFocused: false)
        #expect(paused.canEnd && paused.canCapture && paused.resumes)

        _ = take.finish(at: start.addingTimeInterval(9))
        let finishing = RecordingMenuState(take: take, showsRecording: true, composerFocused: false)
        #expect(!finishing.canEnd && !finishing.canCapture && !finishing.canDiscard && !finishing.stopOwnsCommandReturn)
    }

    @Test("the Stage's buttons keep no ⌘⏎ or ⌘B of their own: the Recording menu is the one source")
    func stageLeavesTheShortcutsToTheMenu() throws {
        let stage = try appSource("Views/Recording/StageControls")
        #expect(!stage.contains(#".keyboardShortcut("b", modifiers: .command)"#))
        #expect(!stage.contains(".keyboardShortcut(.return, modifiers: .command)"))
    }
}

/// A menu delegate that, like a SwiftUI that redraws on every refresh, reports a drawing each time it is asked.
@MainActor
private final class RedrawingMenuDelegate: NSObject, NSMenuDelegate {
    let refresher: () -> RecordingMenuRefresher?
    private(set) var refreshes = 0

    init(refresher: @escaping () -> RecordingMenuRefresher?) {
        self.refresher = refresher
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshes += 1
        refresher()?.menuDrew()
    }
}

@MainActor
@Suite("Recording menu refresher")
struct RecordingMenuRefresherTests {
    @Test("a drawing made while the refresher asks the menu asks nothing more, so a menu that redraws on every refresh can't loop")
    func noLoop() async {
        let menu = NSMenu(title: "Recording")
        var refresher: RecordingMenuRefresher?
        let delegate = RedrawingMenuDelegate { refresher }
        menu.delegate = delegate
        refresher = RecordingMenuRefresher { menu }

        refresher?.menuDrew()
        refresher?.menuDrew()
        let asked = await waitUntil { delegate.refreshes == 1 }
        #expect(asked, "two drawings in one turn ask the menu once")
        await settle(for: .milliseconds(100))

        #expect(delegate.refreshes == 1)
        refresher = nil
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

        @Test("Reveal in Finder on a failed take whose recording was deleted lets the take go as Retry does, and gives the same notice, with the way to Recently Deleted")
        func revealAfterTheEntryWasDeleted() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "engine boom")
                ))
                let model = makeRecordingModel("reveal-stage-deleted")
                model.selectedModel = "openai_whisper-tiny"
                try FileManager.default.createDirectory(at: model.inflightRecordingsURL, withIntermediateDirectories: true)
                let working = try makeTakeWAV("reveal", seconds: 1, in: model.inflightRecordingsURL, prefix: "parola-mic")
                defer { try? FileManager.default.removeItem(at: working) }
                recordAndStop(model, audio: working, seconds: 2)
                let failedOnStage = await waitUntil {
                    if case .failed = model.recording?.state { return true }
                    return false
                }
                #expect(failedOnStage)
                let saved = try #require(await landedEntry(model))
                await waitUntil { !model.hasPendingTakeWork }
                model.deleteEntry(saved.id)
                let deleted = await waitUntil { await model.library.list().isEmpty }
                #expect(deleted)

                model.revealFailedTake()

                let told = await waitUntil { model.exportNotice?.message == Self.restoreFirst }
                #expect(told)
                #expect(model.recording == nil, "the failed Stage stayed up over the notice")
                #expect(!model.noticesWaitForStage)
                let released = await waitUntil { !FileManager.default.fileExists(atPath: working.path) }
                #expect(released, "the deleted entry keeps the audio, so the working file goes")
                let show = try #require(model.exportNotice?.actions.first)
                #expect(show.title == "Show Recently Deleted")
                model.performNoticeAction(show)
                #expect(model.route == .recentlyDeleted)
            }
        }

        @Test("the deleted-recording notice leads to Recently Deleted only while the recording is there")
        func deletedNoticeAction() {
            let restorable = AppModel.deletedTakeNotice(restorable: true)
            #expect(restorable.actions.map(\.handler) == [.openRecentlyDeleted])
            #expect(AppModel.deletedTakeNotice(restorable: false).actions.isEmpty)
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
    @Test("VoiceOver hears \"Recording\" once, then the time, and once the take stops, what became of it")
    func spokenValue() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var take = capturingTake(at: start)
        let at = start.addingTimeInterval(754)
        #expect(SidebarRecordingRow.spokenValue(for: take, at: at, locale: english) == "12 minutes, 34 seconds")
        _ = take.pause(at: at)
        #expect(SidebarRecordingRow.spokenValue(for: take, at: at, locale: english) == "Paused, 12 minutes, 34 seconds")
        _ = take.resume(at: at)
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
                #expect(model.stageHoldsTake, "a take transcribing on its Stage keeps the row")
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

                #expect(model.stageHoldsTake)
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

/// The app's own main menu, read as AppKit holds it: nothing here asks SwiftUI to rebuild it.
@MainActor
private enum AppMenu {
    /// What the item holds with ⌘ alone; "" when it holds nothing.
    static func shortcut(of title: String) -> String? {
        let localized = String(localized: String.LocalizationValue(title))
        guard let item = RecordingMenuRefresher.recordingMenu()?.items.first(where: { $0.title == localized }) else { return nil }
        guard !item.keyEquivalent.isEmpty else { return "" }
        return item.keyEquivalentModifierMask == .command ? item.keyEquivalent : "\(item.keyEquivalentModifierMask.rawValue)+\(item.keyEquivalent)"
    }

    /// What AppKit does as the user opens the menu.
    static func open() throws {
        let menu = try #require(RecordingMenuRefresher.recordingMenu())
        menu.delegate?.menuNeedsUpdate?(menu)
    }

    static func key(_ character: String, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: keyCode
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
        host.dismissTakeSaved()
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
        await MockLanguageModelStore.shared.install(provider: nil, response: MockLanguageModelResponse(text: "Yes, Friday.", delayMs: 3_000))
        do {
            try await body()
            await MockLanguageModelStore.shared.clear()
        } catch {
            await MockLanguageModelStore.shared.clear()
            throw error
        }
    }
}

/// The test host's own app: its real main menu and main window, its status item and pill off for the test.
@MainActor
private func withHostApp(_ body: @MainActor (AppModel, NSWindow) async throws -> Void) async throws {
    let host = try #require(AppDelegate.launchModel)
    let library = host.library.libraryURL.standardizedFileURL.path
    try #require(library == TestHostSandbox.current.library.standardizedFileURL.path, "the host's library is the test sandbox, whose entries this empties")
    let window = try #require(host.mainWindow)
    let found = HostModelState(host)
    host.showRecordingStatusItem = false
    host.showRecordingPill = false
    defer { found.restore(host) }
    try await body(host, window)
    await waitUntil(timeoutMs: 30_000) { !host.hasPendingTakeWork }
    for entry in await host.library.list() { try? await host.library.purge(entry.id) }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("⌘⏎ and ⌘B through the app's own menu and main window", .serialized)
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

        /// The chat page of a loaded transcript, with its composer drawn.
        private func openChat(_ host: AppModel, in window: NSWindow) async throws -> NSTextField {
            let previousGone = await waitUntil { composer(in: window) == nil }
            #expect(previousGone, "a chat page an earlier test left is gone before this one opens")
            host.transcript = Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 4, text: "we ship the patch on Friday")],
                language: "en", modelName: "stub"
            )
            host.phase = .ready
            host.route = .transcript
            host.setTranscriptPaneMode(.chat)
            let shown = await waitUntil(timeoutMs: 10_000) { composer(in: window) != nil }
            #expect(shown)
            return try #require(composer(in: window))
        }

        @Test("right after a take starts, ⌘B marks it and ⌘⏎ stops it, with no menu opened")
        func shortcutsReachANewTake() async throws {
            let audio = try makeTakeWAV("shortcuts-new-take", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "stopped by its shortcut")])
                try await withHostApp { host, window in
                    let idle = await waitUntil { AppMenu.shortcut(of: "Stop Recording") == "" }
                    #expect(idle, "with no take nothing holds ⌘⏎")
                    host.installTestTake(source: .microphone, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -1))
                    let offered = await waitUntil { AppMenu.shortcut(of: "Stop Recording") == "\r" }
                    #expect(offered, "the menu follows the take with nothing opening it")

                    NSApp.sendEvent(try AppMenu.key("b", keyCode: 11, in: window))
                    let marked = host.recording?.markers.count == 1
                    #expect(marked, "⌘B marks the take")
                    NSApp.sendEvent(try AppMenu.key("\r", keyCode: 36, in: window))
                    let stopping = host.recording?.isCapturing == false
                    #expect(stopping, "⌘⏎ stops the take")
                    let landed = await landedEntry(host, timeoutMs: 30_000)
                    #expect(landed != nil)
                }
            }
        }

        @Test("⌘⏎ belongs to Send while the chat composer has the keyboard, and to Stop again once it lets go, with no menu opened")
        func commandReturnFollowsTheComposer() async throws {
            let audio = try makeTakeWAV("command-return", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                try await withChatModel {
                    await installMockTranscriber(segments: [(0, 1, "stopped from the menu")])
                    try await withHostApp { host, window in
                        host.installTestTake(source: .microphone, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -1))
                        let field = try await openChat(host, in: window)

                        #expect(enter("Is Friday still the date?", into: field, in: window))
                        let focused = await waitUntil { host.chatComposerHasFocus }
                        #expect(focused)
                        let handedToSend = await waitUntil { AppMenu.shortcut(of: "Stop Recording") == "" }
                        #expect(handedToSend)
                        NSApp.sendEvent(try AppMenu.key("\r", keyCode: 36, in: window))
                        let recordingWhileTyping = host.recording?.state == .recording
                        #expect(recordingWhileTyping, "⌘⏎ in the composer never stops the take")
                        // The test host is never active, so it has no key window; this is the turn AppKit gives the key window before the menu.
                        let sent = window.performKeyEquivalent(with: try AppMenu.key("\r", keyCode: 36, in: window))
                        #expect(sent, "Send holds ⌘⏎ in the composer")
                        let cleared = await waitUntil { field.stringValue.isEmpty }
                        #expect(cleared)

                        NSApp.sendEvent(try AppMenu.key("\r", keyCode: 36, in: window))
                        let sendingTookIt = window.performKeyEquivalent(with: try AppMenu.key("\r", keyCode: 36, in: window))
                        #expect(!sendingTookIt, "nothing takes ⌘⏎ while the composer is empty and a message is on its way")
                        let recordingWhileSending = host.recording?.state == .recording
                        #expect(recordingWhileSending)

                        #expect(enter("and the venue?", into: field, in: window))
                        #expect(window.makeFirstResponder(nil))
                        let left = await waitUntil { !host.chatComposerHasFocus }
                        #expect(left)
                        let handedBack = await waitUntil { AppMenu.shortcut(of: "Stop Recording") == "\r" }
                        #expect(handedBack)
                        let sendLetGo = window.performKeyEquivalent(with: try AppMenu.key("\r", keyCode: 36, in: window))
                        #expect(!sendLetGo, "Send lets go of ⌘⏎ once the composer loses the keyboard")
                        NSApp.sendEvent(try AppMenu.key("\r", keyCode: 36, in: window))
                        let stopping = host.recording?.isCapturing == false
                        #expect(stopping, "out of the composer, ⌘⏎ stops the take")
                        #expect(field.stringValue == "and the venue?")
                        let landed = await landedEntry(host, timeoutMs: 30_000)
                        #expect(landed != nil)
                    }
                }
            }
        }

        @Test("a Recording menu opened once during the take still lets ⌘⏎ go to Send when the composer takes the keyboard")
        func menuOpenedEarlierDoesNotStealSend() async throws {
            let audio = try makeTakeWAV("command-return-opened", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                try await withChatModel {
                    try await withHostApp { host, window in
                        host.installTestTake(source: .microphone, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -1))
                        let field = try await openChat(host, in: window)
                        let opened = await waitUntil { (try? AppMenu.open()) != nil && AppMenu.shortcut(of: "Stop Recording") == "\r" }
                        #expect(opened, "the user opens the menu once the take is in it")

                        #expect(enter("Is Friday still the date?", into: field, in: window))
                        let focused = await waitUntil { host.chatComposerHasFocus }
                        #expect(focused)
                        let handedToSend = await waitUntil { AppMenu.shortcut(of: "Stop Recording") == "" }
                        #expect(handedToSend)
                        NSApp.sendEvent(try AppMenu.key("\r", keyCode: 36, in: window))

                        let recording = host.recording?.state == .recording
                        #expect(recording, "the ⌘⏎ the menu held when it opened is gone once the composer has the keyboard")
                    }
                }
            }
        }
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Ending a take that is still starting, from outside the Stage", .serialized)
    struct ArmingTakeRemoteTests {
        private static let pinnedModel = "openai_whisper-tiny"

        /// A take whose capture is up but has heard nothing, so it still arms; its file is too small to hold a recording.
        private func startArmingTake(_ label: String) async throws -> (AppModel, URL) {
            let audio = try makeTakeWAV(label, seconds: 0.1, prefix: "parola-test")
            let model = makeRecordingModel(label)
            model.useStreaming = false
            model.selectedModel = Self.pinnedModel
            model.takeCaptureOverride = { _ in StubSource(url: audio) }
            model.startRecording(source: .microphone)
            let captureUp = await waitUntil { model.takeInProgress }
            #expect(captureUp)
            return (model, audio)
        }

        @Test("Stop from the menu bar, the pill, the Recording menu or ⌘⏎ ends a take still starting quietly, as the Stage's Cancel does")
        func stopWhileStartingCancels() async throws {
            let (model, audio) = try await startArmingTake("remote-stop-starting")
            defer { try? FileManager.default.removeItem(at: audio) }
            defer { model.cancelCurrentWork() }
            #expect(model.recording?.state == .arming(.startingCapture))

            TakeRemote.stop(model)

            let ended = await waitUntil { model.recording == nil }
            #expect(ended, "no failed Stage saying nothing was recorded")
            #expect(model.exportNotice == nil)
            #expect(model.phase == .idle)
            let saved = await model.library.list()
            #expect(saved.isEmpty)
        }

        @Test("Stop while a live take's model still loads ends it with no word")
        func stopWhilePreparingCancels() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                let model = makeRecordingModel("remote-stop-preparing")
                model.selectedModel = Self.pinnedModel
                let gate = MockTranscriberGate()
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                    partials: ["hello"], downloadFractions: [0.5], delayMs: 5_000, gate: gate
                ))
                model.useStreaming = true
                model.startRecording(source: .microphone)
                let preparing = await waitUntil {
                    if case .arming(.preparingModel) = model.recording?.state { return true }
                    return false
                }
                #expect(preparing)

                TakeRemote.stop(model)

                #expect(model.recording == nil)
                #expect(model.exportNotice == nil)
                let released = await waitUntil { !model.recordingActive }
                #expect(released)
                await gate.open()
                await settle()
                #expect(model.recording == nil)
                let saved = await model.library.list()
                #expect(saved.isEmpty)
            }
        }

        @Test("the mic hotkey ends a take still loading its model quietly, as every other Stop does")
        func micHotkeyWhilePreparingCancels() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                let model = makeRecordingModel("hotkey-stop-preparing")
                model.selectedModel = Self.pinnedModel
                let gate = MockTranscriberGate()
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                    partials: ["hello"], downloadFractions: [0.5], delayMs: 5_000, gate: gate
                ))
                model.useStreaming = true
                model.toggleMicRecording()
                let preparing = await waitUntil {
                    if case .arming(.preparingModel) = model.recording?.state { return true }
                    return false
                }
                #expect(preparing)

                model.toggleMicRecording()

                #expect(model.recording == nil, "no failed Stage saying nothing was recorded")
                #expect(model.exportNotice == nil)
                let released = await waitUntil { !model.recordingActive }
                #expect(released)
                await gate.open()
                await settle()
                let saved = await model.library.list()
                #expect(saved.isEmpty)
            }
        }

        @Test("a Stop right after the first buffer came in keeps the take, though the take had not been marked recording yet")
        func stopRightAfterTheFirstBufferKeepsTheTake() async throws {
            let audio = try makeTakeWAV("stop-first-buffer", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "just in time")])
                let model = makeRecordingModel("stop-first-buffer")
                model.useStreaming = false
                model.selectedModel = Self.pinnedModel
                let capture = MeteredCapture(file: audio)
                model.takeCaptureOverride = { _ in capture }
                model.startRecording(source: .microphone)
                let up = await waitUntil { model.liveSource != nil }
                #expect(up)
                #expect(model.recording?.isArming == true)

                capture.levelMeter.record(0.4)
                TakeRemote.stop(model)

                #expect(model.recording?.state == .finishing, "the take is kept and stops as any recording take does")
                let landed = await landedEntry(model, timeoutMs: 30_000)
                #expect(landed != nil)
            }
        }

        @Test("Discard… on a take still starting ends it without asking: there is no audio to delete")
        func discardWhileStartingAsksNothing() async throws {
            let (model, audio) = try await startArmingTake("remote-discard-starting")
            defer { try? FileManager.default.removeItem(at: audio) }
            defer { model.cancelCurrentWork() }
            var asked = 0

            let ended = await TakeRemote.discard(model) { asked += 1; return true }

            #expect(ended)
            #expect(asked == 0)
            let gone = await waitUntil { model.recording == nil }
            #expect(gone)
            #expect(model.exportNotice == nil)
        }
    }
}

/// A capture that is up at once and meters only what the test records; Stop hands back its file.
private actor MeteredCapture: LiveAudioSource {
    nonisolated let levelMeter = LevelMeter()
    private let file: URL

    init(file: URL) { self.file = file }

    func start() async throws {}
    func prepare() async throws -> URL { file }
    func cancel() async {}
}

/// A capture that hands back its file, cut short, only once the test lets it go.
private actor HeldCapture: LiveAudioSource {
    nonisolated let levelMeter = LevelMeter()
    private let file: URL
    private var released = false
    private var held: CheckedContinuation<Void, Never>?

    init(file: URL) { self.file = file }

    func start() async throws {}

    func prepare() async throws -> URL {
        if !released { await withCheckedContinuation { held = $0 } }
        throw CaptureInterrupted(url: file, reason: "the disk is full")
    }

    func letGo() {
        released = true
        held?.resume()
        held = nil
    }

    func cancel() async {}
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("One rule for whether the Stage holds a take", .serialized)
    struct StageHoldsTakeTests {
        @Test("a take let go to its save holds no Stage: no sidebar row, no Show Recording, and showStage changes nothing")
        func letGoTakeHoldsNoStage() async throws {
            let audio = try makeTakeWAV("stage-holds-let-go", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            let model = makeRecordingModel("stage-holds-let-go")
            model.useStreaming = false
            model.selectedModel = "openai_whisper-tiny"
            let capture = HeldCapture(file: audio)
            model.takeCaptureOverride = { _ in capture }
            model.startRecording(source: .microphone)
            let up = await waitUntil { model.liveSource != nil }
            #expect(up)
            model.stopRecordingAndTranscribe()
            #expect(model.stageHoldsTake, "a finishing take is still on its Stage")

            model.cancelCurrentWork()

            #expect(model.recording?.state == .transcribing(progress: nil), "let go to its save")
            #expect(!model.stageHoldsTake)
            let page = model.route
            #expect(!model.showStage())
            #expect(model.route == page)
            let menu = RecordingMenuState(take: model.recording, showsRecording: model.stageHoldsTake, composerFocused: false)
            #expect(!menu.canShow)
            let sidebar = HostedWindow(LibrarySidebar().environment(model), width: 240, height: 600)
            defer { sidebar.close() }
            _ = await waitUntil { sidebar.rowCount > 3 }
            #expect(sidebar.row(identifiedBy: "Sidebar.Row.Recording") == nil)

            await capture.letGo()
            await waitUntil { !model.hasPendingTakeWork }
        }

        @Test("Stop Transcribing lets the take go from its Stage at once, and the row and Show Recording go with it")
        func stopTranscribingLetsTheStageGo() async throws {
            let audio = try makeTakeWAV("stage-holds-run", seconds: 2)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await installMockTranscriber(segments: [(0, 1, "words")], partials: ["some"], gate: gate)
                let model = makeRecordingModel("stage-holds-run")
                model.selectedModel = "openai_whisper-tiny"
                recordAndStop(model, audio: audio, seconds: 2)
                let onStage = await waitUntil { ContentRoutes.stageTranscription(for: model) != nil }
                #expect(onStage)
                #expect(model.stageHoldsTake, "a take transcribing on its Stage holds it")

                model.stopTranscribingTake()

                #expect(model.recording?.isTranscribing == true, "the take still saves")
                #expect(!model.stageHoldsTake)
                #expect(!model.showStage())
                let saved = await landedEntry(model)
                #expect(saved != nil)
                await gate.open()
                await waitUntil { !model.hasPendingTakeWork }
            }
        }
    }
}
