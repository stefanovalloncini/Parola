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
private func capsuleFill(_ take: RecordingSession, dark: Bool) throws -> NSColor {
    let face = SessionCapsuleFace(take: take, showsMeter: false, isOnScreen: false, showStage: {}, stop: {})
        .environment(\.controlActiveState, .inactive)
        .environment(\.colorScheme, dark ? .dark : .light)
    let renderer = ImageRenderer(content: face)
    renderer.scale = 2
    var image: CGImage?
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
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

    @Test("its red is a solid fill, so an inactive window leaves it red in both appearances")
    @MainActor
    func solidRedWhenInactive() throws {
        let take = capturingTake(at: Date(timeIntervalSinceNow: -754))
        guard case .dynamic(let light, let dark) = DS.Color.recordingFillTheme else {
            Issue.record("the recording red is not a fixed pair")
            return
        }
        let lightFill = try capsuleFill(take, dark: false)
        let darkFill = try capsuleFill(take, dark: true)
        #expect(matches(lightFill, light), "light fill \(lightFill)")
        #expect(matches(darkFill, dark), "dark fill \(darkFill)")
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

                SessionCapsule.stopOrCancel(model)

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
