import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

private func italianBundle() throws -> Bundle {
    let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
    return try #require(Bundle(path: path))
}

@MainActor
@Suite("Recording surface settings")
struct RecordingSurfaceSettingsTests {
    private func makeModel(_ defaults: UserDefaults) -> AppModel {
        AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("surface-settings"))
    }

    @Test("the menu bar item and the pill start on, and each switch is kept and read back")
    func togglesPersist() {
        let defaults = temporaryDefaults()
        let model = makeModel(defaults)
        #expect(model.showRecordingStatusItem)
        #expect(model.showRecordingPill)

        model.showRecordingStatusItem = false
        model.showRecordingPill = false
        #expect(defaults.object(forKey: "showRecordingStatusItem") as? Bool == false)
        #expect(defaults.object(forKey: "showRecordingPill") as? Bool == false)

        defaults.set(true, forKey: "showRecordingPill")
        model.reloadSettings()
        #expect(model.showRecordingStatusItem == false)
        #expect(model.showRecordingPill)
    }

    @Test("the Microphone pane's reset turns both back on, and the bridge may set them")
    func resetAndBridge() {
        for key in ["showRecordingStatusItem", "showRecordingPill"] {
            #expect(SettingsPaneScope.microphone.defaultsKeys.contains(key))
            #expect(ParolaAutomationServer.writableSettingKeys.contains(key))
        }
        let defaults = temporaryDefaults()
        let model = makeModel(defaults)
        model.showRecordingStatusItem = false
        model.showRecordingPill = false

        for key in SettingsPaneScope.microphone.defaultsKeys { defaults.removeObject(forKey: key) }
        model.reloadSettings()

        #expect(model.showRecordingStatusItem)
        #expect(model.showRecordingPill)
    }

    @Test("Settings search finds them from the menu bar or the pill")
    func search() {
        #expect(SettingsSidebarCatalog.matches(route: .microphone, query: "pill"))
        #expect(SettingsSidebarCatalog.matches(route: .microphone, query: "menu bar"))
    }

    @Test("the rows read in Italian")
    func italian() throws {
        let it = try italianBundle()
        #expect(String(localized: "Recording controls", bundle: it) == "Controlli di registrazione")
        #expect(String(localized: "Show the recording in the menu bar", bundle: it) == "Mostra la registrazione nella barra dei menu")
        #expect(
            String(localized: "The time stays in the menu bar while you record, with the recording's controls in its menu.", bundle: it)
                == "Il tempo resta nella barra dei menu mentre registri, con i controlli della registrazione nel suo menu."
        )
        #expect(
            String(localized: "Show a floating recording pill when Parola is in the background", bundle: it)
                == "Mostra una pillola di registrazione fluttuante quando Parola è in background"
        )
        #expect(
            String(localized: "The time and a Stop button float over other apps. Drag the pill wherever you like.", bundle: it)
                == "Il tempo e il pulsante Ferma restano sopra le altre app. Trascina la pillola dove preferisci."
        )
    }
}

private func capturingTake(arming: RecordingSession.Arming = .startingCapture) -> RecordingSession {
    RecordingSession(takeID: 1, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: arming)
}

@Suite("Recording status item and pill")
struct RecordingStatusItemTests {
    @Test("the status item's menu offers the take's controls")
    func menu() {
        var take = capturingTake()
        _ = take.markCapturing(at: .now)
        #expect(RecordingStatusItem.menuTitles(for: take)
            == ["Stop Recording", "Pause", "Add Marker", "Discard…", "Show Parola"])
        _ = take.pause(at: .now)
        #expect(RecordingStatusItem.menuTitles(for: take)[1] == "Resume")
    }

    @Test("Pause and Mark wait for a capture; Stop and Discard… have nothing left once the take finishes")
    func enabledControls() {
        var take = capturingTake(arming: .countIn(remaining: 3))
        #expect(RecordingStatusItem.controls(for: take).map(\.isEnabled) == [true, false, false, true, true])
        _ = take.markCapturing(at: .now)
        #expect(RecordingStatusItem.controls(for: take).map(\.isEnabled) == [true, true, true, true, true])
        _ = take.pause(at: .now)
        #expect(RecordingStatusItem.controls(for: take).map(\.isEnabled) == [true, true, true, true, true])
        _ = take.resume(at: .now)
        _ = take.finish(at: .now)
        #expect(RecordingStatusItem.controls(for: take).map(\.isEnabled) == [false, false, false, false, true])
    }

    @Test("the title is the take's light and its clock: grey at 0:00 while it starts, red and ticking, amber and held while it pauses")
    func title() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var take = capturingTake()
        #expect(RecordingStatusItem.title(for: take, now: start) == "● 0:00")
        #expect(TakeRemote.lamp(for: take) == .waiting)

        _ = take.markCapturing(at: start)
        #expect(RecordingStatusItem.title(for: take, now: start.addingTimeInterval(754)) == "● 12:34")
        #expect(TakeRemote.lamp(for: take) == .recording)

        _ = take.pause(at: start.addingTimeInterval(754))
        #expect(RecordingStatusItem.title(for: take, now: start.addingTimeInterval(800)) == "● 12:34")
        #expect(TakeRemote.lamp(for: take) == .paused)

        _ = take.resume(at: start.addingTimeInterval(800))
        #expect(RecordingStatusItem.title(for: take, now: start.addingTimeInterval(3_700)) == "● 1:00:54")
        _ = take.finish(at: start.addingTimeInterval(3_700))
        #expect(TakeRemote.lamp(for: take) == .waiting)
    }

    @Test("in the menu bar the dot is red and the digits keep their width, in the bar's own colour")
    func attributedTitle() throws {
        let title = RecordingStatusItem.attributedTitle(clock: "12:34", lamp: .recording)
        #expect(title.string == "● 12:34")
        let dot = try #require(title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let red = try #require(dot.usingColorSpace(.sRGB))
        #expect(red.redComponent > 0.7)
        #expect(red.greenComponent < 0.3)
        #expect(title.attribute(.foregroundColor, at: 2, effectiveRange: nil) == nil)
        let digits = try #require(title.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        #expect(digits.pointSize == NSFont.menuBarFont(ofSize: 0).pointSize)
        #expect(digits.fontDescriptor.object(forKey: .featureSettings) != nil)
    }

    @Test("VoiceOver hears what the take is doing, then its time in words")
    func spoken() {
        let english = Locale(identifier: "en_US")
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var take = capturingTake()
        #expect(TakeRemote.spokenStatus(for: take, at: start, locale: english) == "Getting ready to record")
        _ = take.markCapturing(at: start)
        let at = start.addingTimeInterval(754)
        #expect(TakeRemote.spokenStatus(for: take, at: at, locale: english) == "Recording, 12 minutes, 34 seconds")
        _ = take.pause(at: at)
        #expect(TakeRemote.spokenStatus(for: take, at: at, locale: english) == "Paused, 12 minutes, 34 seconds")
        _ = take.resume(at: at)
        _ = take.finish(at: at)
        #expect(TakeRemote.spokenStatus(for: take, at: at, locale: english) == "Finishing, 12 minutes, 34 seconds")
    }

    @Test("the pill shows only in the background, during a take, when it's on")
    func pill() {
        #expect(RecordingPill.shouldShow(appActive: false, takeRunning: true, enabled: true))
        #expect(!RecordingPill.shouldShow(appActive: true, takeRunning: true, enabled: true))
        #expect(!RecordingPill.shouldShow(appActive: false, takeRunning: false, enabled: true))
        #expect(!RecordingPill.shouldShow(appActive: false, takeRunning: true, enabled: false))
    }

    @Test("the pill sits where it was left, or bottom centre of the main screen when that spot is gone")
    func placement() {
        let size = NSSize(width: 160, height: 42)
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let kept = RecordingPill.frame(size: size, remembered: NSPoint(x: 1200, y: 700), screens: [screen], fallback: screen)
        #expect(kept == NSRect(x: 1200, y: 700, width: 160, height: 42))
        let offScreen = RecordingPill.frame(size: size, remembered: NSPoint(x: 1400, y: 700), screens: [screen], fallback: screen)
        #expect(offScreen.origin == NSPoint(x: 640, y: 100))
        let fresh = RecordingPill.frame(size: size, remembered: nil, screens: [screen], fallback: screen)
        #expect(fresh == NSRect(x: 640, y: 100, width: 160, height: 42))
        let second = NSRect(x: 1440, y: 0, width: 1920, height: 1055)
        let onTheOther = RecordingPill.frame(size: size, remembered: NSPoint(x: 3000, y: 50), screens: [screen, second], fallback: screen)
        #expect(onTheOther.origin == NSPoint(x: 3000, y: 50))
    }

    @Test("the strings read in Italian")
    func italian() throws {
        let it = try italianBundle()
        let italian = Locale(identifier: "it_IT")
        #expect(String(localized: "Show Parola", bundle: it) == "Mostra Parola")
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var take = capturingTake()
        #expect(TakeRemote.spokenStatus(for: take, at: start, bundle: it, locale: italian) == "Preparazione della registrazione")
        _ = take.markCapturing(at: start)
        let at = start.addingTimeInterval(754)
        let time = AppFormat.spokenDuration(seconds: 754, locale: italian)
        #expect(TakeRemote.spokenStatus(for: take, at: at, bundle: it, locale: italian) == "Registrazione, \(time)")
        _ = take.pause(at: at)
        #expect(TakeRemote.spokenStatus(for: take, at: at, bundle: it, locale: italian) == "In pausa, \(time)")
        _ = take.resume(at: at)
        _ = take.finish(at: at)
        #expect(TakeRemote.spokenStatus(for: take, at: at, bundle: it, locale: italian) == "Chiusura in corso, \(time)")
    }
}

@MainActor
@Suite("Recording surfaces follow the take", .serialized)
struct RecordingSurfaceTests {
    @Test("the status item comes with the take, follows its pause and its setting, and goes with it")
    func statusItemFollowsTheTake() async throws {
        let audio = try tempWAV("status-item")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("status-item")
        let item = RecordingStatusItem(statusBar: nil)
        item.bind(model)
        #expect(item.face == nil)

        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -754))
        let shown = await waitUntil { item.face?.clock.hasPrefix("12:3") == true }
        #expect(shown)
        #expect(item.face?.lamp == .recording)
        #expect(item.face?.menuTitles == ["Stop Recording", "Pause", "Add Marker", "Discard…", "Show Parola"])

        #expect(model.pauseTake())
        let paused = await waitUntil { item.face?.lamp == .paused }
        #expect(paused)
        #expect(item.face?.menuTitles[1] == "Resume")

        model.showRecordingStatusItem = false
        let hidden = await waitUntil { item.face == nil }
        #expect(hidden)
        model.showRecordingStatusItem = true
        let back = await waitUntil { item.face != nil }
        #expect(back)

        model.endTestTake()
        let gone = await waitUntil { item.face == nil }
        #expect(gone)
    }

    @Test("the pill shows while Parola is in the background with a take running, and only then")
    func pillFollowsTheTakeAndActivation() async throws {
        let audio = try tempWAV("pill")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("pill")
        let pill = RecordingPill(makesPanel: false)
        pill.bind(model, appActive: true)

        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        await settle()
        #expect(!pill.isShown)
        pill.appActiveChanged(false)
        #expect(pill.isShown)

        model.showRecordingPill = false
        let off = await waitUntil { !pill.isShown }
        #expect(off)
        model.showRecordingPill = true
        let on = await waitUntil { pill.isShown }
        #expect(on)

        pill.appActiveChanged(true)
        #expect(!pill.isShown)
        pill.appActiveChanged(false)
        #expect(pill.isShown)

        model.endTestTake()
        let gone = await waitUntil { !pill.isShown }
        #expect(gone)
    }

    @Test("Show Parola puts the Stage up before the window comes forward")
    func showParola() throws {
        let audio = try tempWAV("show-parola")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("show-parola")
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        model.route = .transcript

        var routeWhenForward: AppModel.Route?
        TakeRemote.showParola(model) { routeWhenForward = model.route }

        #expect(routeWhenForward == .recording)
        #expect(model.route == .recording)
        model.endTestTake()
    }

    @Test("Stop during a count-in ends it as its own Cancel does")
    func stopEndsACountIn() {
        let model = makeRecordingModel("remote-stop-count-in")
        model.recordingCountInSeconds = 3
        model.startRecording(source: .microphone)
        // A Stop that fails to end the count-in would otherwise reach the microphone three seconds on.
        defer { model.cancelRecordingCountdown() }
        #expect(model.recordingCountdown != nil)

        TakeRemote.stop(model)

        #expect(model.recordingCountdown == nil)
        #expect(model.recording == nil)
    }

    @Test("Discard… asks first, and a refused question keeps the take")
    func discardAsksFirst() async throws {
        let audio = try tempWAV("remote-discard")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("remote-discard")
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))

        var asked = 0
        let kept = await TakeRemote.discard(model) { asked += 1; return false }

        #expect(asked == 1)
        #expect(!kept)
        #expect(model.recording?.state == .recording)
        model.endTestTake()
    }

    @Test("a count-in runs only with Parola in front; in the background the take starts at once")
    func countInNeedsParolaInFront() throws {
        let audio = try tempWAV("count-in-front")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("count-in-front")
        model.useStreaming = false
        model.takeCaptureOverride = { _ in StubSource(url: audio) }
        model.recordingCountInSeconds = 3
        defer { model.cancelCurrentWork() }

        model.startRecording(source: .microphone)
        #expect(model.recordingCountdown == 3)
        model.cancelRecordingCountdown()
        #expect(model.recording == nil)

        model.appIsActive = { false }
        model.startRecording(source: .microphone)
        #expect(model.recordingCountdown == nil)
        #expect(model.recording?.state == .arming(.startingCapture))
    }
}

// Closures inside #expect/#require arguments can share a symbol with a later closure in the same test (Swift 6.4); bind waits first.
extension TranscriberMockSuites {
    @MainActor
    @Suite("Recording surfaces stop the take", .serialized)
    struct RecordingSurfaceStopTests {
        @Test("Stop from the menu bar or the pill stops a running take and lets it land")
        func stopLandsTheTake() async throws {
            let audio = try makeTakeWAV("remote-stop", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "stopped from afar")])
                let model = makeRecordingModel("remote-stop")
                model.installTestTake(source: .microphone, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -1))

                TakeRemote.stop(model)

                let stopping = model.recording?.isCapturing == false
                #expect(stopping)
                let landed = await landedEntry(model, timeoutMs: 30_000)
                #expect(landed != nil)
            }
        }
    }
}

@Suite("Recording surfaces wiring")
struct RecordingSurfaceWiringTests {
    private func source(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/RecordingStatusItemTests.swift",
            with: "ParolaApp/\(name).swift"
        )
        return try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("the app delegate binds both surfaces and tells the pill when Parola goes to the background and comes back")
    func delegateWiring() throws {
        let delegate = try source("AppDelegate")
        #expect(delegate.contains("recordingStatusItem.bind(model)"))
        #expect(delegate.contains("recordingPill.bind(model, appActive: NSApp.isActive)"))
        #expect(delegate.contains("func applicationDidResignActive(_ notification: Notification) { model?.handleAppResignedActive() recordingPill.appActiveChanged(false) }"))
        #expect(delegate.contains("func applicationDidBecomeActive(_ notification: Notification) { recordingPill.appActiveChanged(true)"))
    }

    @Test("the menu bar's record actions leave Parola where it is")
    func menuBarRecordActions() throws {
        let menuBar = try source("MenuBarController")
        #expect(menuBar.contains("@objc private func recordMic() { model?.startRecording(source: .microphone) }"))
        #expect(menuBar.contains("@objc private func recordSystem() { model?.startRecording(source: .systemAudio) }"))
        #expect(!menuBar.contains("openParola() model?.start"))
    }

    @Test("the Microphone pane shows both switches")
    func paneRows() throws {
        let pane = try source("Views/Settings/MicrophonePane")
        #expect(pane.contains("Toggle(\"\", isOn: $model.showRecordingStatusItem)"))
        #expect(pane.contains("Toggle(\"\", isOn: $model.showRecordingPill)"))
    }
}
