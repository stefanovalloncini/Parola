import AppKit
import SwiftUI
import Testing
@testable import Parola
import ParolaCore

@Suite("Stage layout")
struct StageLayoutTests {
    @Test("the clock reads m:ss, then h:mm:ss after an hour")
    func clock() {
        #expect(StageClock.text(seconds: 0) == "0:00")
        #expect(StageClock.text(seconds: 75) == "1:15")
        #expect(StageClock.text(seconds: 3600) == "1:00:00")
        #expect(StageClock.text(seconds: 3 * 3600 + 5 * 60 + 9) == "3:05:09")
    }

    @Test("the sidebar folds for the take and comes back as it was")
    func sidebarPolicy() {
        #expect(SidebarCollapsePolicy.enter(current: .all) == .detailOnly)
        #expect(SidebarCollapsePolicy.exit(previous: .all, current: .detailOnly, userChangedDuringTake: false) == .all)
        #expect(SidebarCollapsePolicy.exit(previous: .detailOnly, current: .detailOnly, userChangedDuringTake: false) == .detailOnly)
        #expect(SidebarCollapsePolicy.exit(previous: .all, current: .all, userChangedDuringTake: true) == .all)
        #expect(SidebarCollapsePolicy.exit(previous: .detailOnly, current: .all, userChangedDuringTake: true) == .all)
    }

    @Test("the clock counts the take's capture, stands still through a pause and ticks on the take's own seconds")
    func clockSkipsPauses() throws {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var take = RecordingSession(
            takeID: 1, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: .startingCapture
        )
        #expect(take.clockOrigin == nil)
        _ = take.markCapturing(at: start)
        #expect(StageClock.text(seconds: Int(take.elapsed(at: start.addingTimeInterval(75.6)))) == "1:15")
        _ = take.pause(at: start.addingTimeInterval(75.6))
        #expect(StageClock.text(seconds: Int(take.elapsed(at: start.addingTimeInterval(90)))) == "1:15")
        _ = take.resume(at: start.addingTimeInterval(90.2))
        let origin = try #require(take.clockOrigin)
        #expect(abs(origin.timeIntervalSince(start) - 14.6) < 0.0001)
        #expect(StageClock.text(seconds: Int(take.elapsed(at: start.addingTimeInterval(100.2)))) == "1:25")
    }

    @Test("the clock speaks its time in words, hours, minutes and seconds past the hour")
    func spokenClock() {
        let english = Locale(identifier: "en_US")
        let italian = Locale(identifier: "it_IT")
        #expect(AppFormat.spokenDuration(seconds: 0, locale: english) == "0 seconds")
        #expect(AppFormat.spokenDuration(seconds: 754, locale: english) == "12 minutes, 34 seconds")
        #expect(AppFormat.spokenDuration(seconds: 3725, locale: english) == "1 hour, 2 minutes, 5 seconds")
        #expect(AppFormat.spokenDuration(seconds: 3 * 3600 + 5 * 60 + 9, locale: english) == "3 hours, 5 minutes, 9 seconds")
        #expect(AppFormat.spokenDuration(seconds: 0, locale: italian) == "0 secondi")
        #expect(AppFormat.spokenDuration(seconds: 754, locale: italian) == "12 minuti e 34 secondi")
        #expect(AppFormat.spokenDuration(seconds: 3725, locale: italian) == "1 ora, 2 minuti e 5 secondi")
    }

    @Test("the device menu checks the input the take listens on, the default when the chosen one is gone")
    func deviceCheckMark() {
        let builtIn = AudioInputDevice(uid: "built-in", name: "MacBook Pro Microphone", isDefault: true)
        let usb = AudioInputDevice(uid: "usb", name: "USB Mic", isDefault: false)
        let both = [builtIn, usb]
        #expect(StageDeviceMenu.checkedUID(takeDevice: "USB Mic", preferredUID: "usb", devices: both) == "usb")
        #expect(StageDeviceMenu.checkedUID(takeDevice: "MacBook Pro Microphone", preferredUID: "gone", devices: both) == "built-in")
        #expect(StageDeviceMenu.checkedUID(takeDevice: nil, preferredUID: "gone", devices: both) == "built-in")
        #expect(StageDeviceMenu.checkedUID(takeDevice: nil, preferredUID: nil, devices: both) == "built-in")
        #expect(StageDeviceMenu.checkedUID(takeDevice: "USB Mic", preferredUID: nil, devices: both) == "usb")
        #expect(StageDeviceMenu.checkedUID(takeDevice: "Unplugged Mic", preferredUID: nil, devices: both) == nil)
    }

    @Test("the recording light is full as each second turns and faint halfway through it")
    func recDotPulse() {
        #expect(RecDot.pulse(at: 0) == 1)
        #expect(RecDot.pulse(at: 12) == 1)
        #expect(abs(RecDot.pulse(at: 12.5) - 0.35) < 0.0001)
    }

    private func italianBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("the Stage's words have their Italian")
    @MainActor
    func italian() throws {
        let it = try italianBundle()
        #expect(StageFacts.modeLine(isStreaming: true, bundle: it) == "Trascrizione in tempo reale")
        #expect(StageFacts.modeLine(isStreaming: false, bundle: it) == "Trascrizione al termine")
        #expect(StageFacts.modeLine(isStreaming: true) == "Live transcript")
        #expect(String(localized: "Transcript appears when you stop", bundle: it) == "La trascrizione appare quando fermi la registrazione")
        #expect(String(localized: "Stop the recording to change the microphone", bundle: it) == "Ferma la registrazione per cambiare microfono")
        #expect(String(localized: "Pause Recording", bundle: it) == "Metti in pausa la registrazione")
        #expect(String(localized: "The audio is deleted.", bundle: it) == "L'audio viene eliminato.")
    }

    @MainActor
    private func measured(_ font: Font, text: String = "Hxg 019") -> CGSize {
        NSHostingView(rootView: Text(verbatim: text).font(font)).fittingSize
    }

    @Test("the unsettled words clear 4.5:1 on every backdrop the Stage sits on")
    func liveTailIsLegible() {
        let tail = DS.Color.liveTailTheme.appearanceVariants
        for backdrop in [ThemePalette.sharedNeutrals.canvas, ThemePalette.sharedNeutrals.surface] {
            let behind = backdrop.appearanceVariants
            #expect(tail.light.contrast(against: behind.light) >= RGBA.textContrastMinimum)
            #expect(tail.dark.contrast(against: behind.dark) >= RGBA.textContrastMinimum)
        }
    }

    @Test("the Stage's clock is 56 pt SF Rounded light with digits of one width")
    @MainActor
    func stageClockFace() {
        #expect(measured(DS.Font.takeTimerStage) == measured(.system(size: 56, weight: .light, design: .rounded).monospacedDigit()))
        #expect(measured(DS.Font.takeTimerStage) != measured(.system(size: 56, weight: .light, design: .monospaced).monospacedDigit()))
        #expect(measured(DS.Font.takeTimerStage, text: "0:00") == measured(DS.Font.takeTimerStage, text: "1:11"))
        #expect(measured(DS.Font.takeTimerCompact, text: "0:00") == measured(DS.Font.takeTimerCompact, text: "1:11"))
    }

    @Test("the Stage's words are New York 24")
    @MainActor
    func stageTextFace() {
        #expect(measured(DS.Font.liveTranscriptStage) == measured(.system(size: 24, design: .serif)))
        #expect(measured(DS.Font.liveTranscriptStage) != measured(.system(size: 24)))
    }

    /// What can be up under the page when a take starts, each with a control that only its strip draws.
    enum PendingStrip: String, CaseIterable, Sendable {
        case takeSavedElsewhere, failureNotice, takeSavedOnItsStage, watchedFileRunning

        var control: String {
            switch self {
            case .takeSavedElsewhere: "Arrival.Button.Open"
            case .failureNotice: "ExportNotice.Button.Dismiss"
            case .takeSavedOnItsStage: "TakeSaved.Button.Copy"
            case .watchedFileRunning: "Arrival.Button.Stop"
            }
        }

        @MainActor
        func post(on model: AppModel) {
            let title = "Recording 2 Oct 2026 at 10:52"
            switch self {
            case .takeSavedElsewhere:
                let manifest = ParolaDocument.Manifest(originalAudioName: "\(title).m4a", title: title, modelName: "stub", language: "en")
                let entry = LibraryEntry(id: "saved", bundleURL: URL(fileURLWithPath: "/tmp/saved.parola"), manifest: manifest)
                model.arrivalNotice = ArrivalNotice(landed: entry, origin: .take)
            case .failureNotice:
                model.exportNotice = ExportNotice(
                    message: "Auto-export couldn't write to its folder: \(title).txt couldn't be saved.",
                    failures: [], folder: nil, tone: .failure
                )
            case .takeSavedOnItsStage:
                model.takeSavedNotice = TakeSavedNotice(entryID: "saved", category: .transcription)
            case .watchedFileRunning:
                model.runningArrivalNotice = ArrivalNotice(running: URL(fileURLWithPath: "/tmp/\(title).m4a"))
            }
        }
    }

    @MainActor
    private func stageFrames(_ elements: [HostedAccessibility.Element]) throws -> [CGRect] {
        let clock = elements.first { $0.label == "Recording time" }
        let band = elements.first { $0.label == "Input level" }
        let stop = elements.first { $0.identifier?.hasSuffix("Stage.Button.Stop") == true }
        return [try #require(clock).frame, try #require(band).frame, try #require(stop).frame]
    }

    @MainActor
    private func draws(_ control: String, _ elements: [HostedAccessibility.Element]) -> Bool {
        elements.contains { $0.identifier?.hasSuffix(control) == true }
    }

    /// The Stage is up once its clock sits in the middle of the window: the sidebar has folded, and nothing on it is moving.
    @MainActor
    private func stageCameUp(in hosted: HostedWindow) async -> Bool {
        await waitUntil {
            let clock = HostedAccessibility.elements(in: hosted.host).first { $0.label == "Recording time" }
            return clock.map { abs($0.frame.midX - hosted.window.frame.midX) < 0.5 } ?? false
        }
    }

    @Test("a notice or toast pending as a take records leaves the Stage as it is, and waits for the page after it", arguments: PendingStrip.allCases)
    @MainActor
    func pendingStripLeavesTheStage(_ strip: PendingStrip) async throws {
        let model = makeRecordingModel("stage-pending-\(strip.rawValue)")
        let wav = try tempWAV("stage-pending")
        defer { try? FileManager.default.removeItem(at: wav) }
        // A minute in, so the Stage shows without its entrance.
        model.installTestTake(source: .microphone, liveSource: StubSource(url: wav), startedAt: Date(timeIntervalSinceNow: -60))
        let hosted = HostedWindow(ContentView().environment(model))
        defer {
            hosted.close()
            model.endTestTake()
        }
        try #require(await stageCameUp(in: hosted), "the Stage never came up")
        let clear = try stageFrames(HostedAccessibility.elements(in: hosted.host))

        strip.post(on: model)
        await settle(for: .milliseconds(300))

        let onStage = HostedAccessibility.elements(in: hosted.host)
        let pending = try stageFrames(onStage)
        #expect(pending == clear, "the clock, band and controls moved for the \(strip.rawValue) strip")
        #expect(!draws(strip.control, onStage), "the Stage has no room for the strip")

        model.route = .transcript
        let shows = await waitUntil { draws(strip.control, HostedAccessibility.elements(in: hosted.host)) }
        #expect(shows, "the strip waited for the page after the Stage")
    }

    /// What the Stage says on its own line: a run turned away while the take records, or why a finishing take stopped by itself.
    enum StageLine: String, CaseIterable, Sendable {
        case turnedAway, stoppedOnItsOwn

        var message: String {
            switch self {
            case .turnedAway: "Finish the recording first."
            case .stoppedOnItsOwn: "The system audio stopped, so Parola stopped the recording."
            }
        }

        @MainActor
        func setUp(_ model: AppModel) {
            guard self == .stoppedOnItsOwn else { return }
            model.updateSession(of: model.recording?.takeID) { _ = $0.finish(at: Date()) }
        }

        @MainActor
        func post(on model: AppModel) {
            switch self {
            case .turnedAway: model.noteRunWaitsForTake()
            case .stoppedOnItsOwn:
                model.takeStopReason = message
                model.exportNotice = ExportNotice(message: message, failures: [], folder: nil, tone: .failure, forTake: model.recording?.takeID)
            }
        }
    }

    enum StageWindow: String, CaseIterable, Sendable {
        case regular, smallest

        var size: CGSize {
            switch self {
            case .regular: CGSize(width: 1180, height: 760)
            case .smallest: CGSize(width: 920, height: 600)
            }
        }
    }

    private struct Placed: Equatable {
        let name: String
        let frame: CGRect
    }

    /// Every element on the Stage but the line, where it sits; the folded sidebar beside the Stage is not the Stage's.
    @MainActor
    private func placed(onStageOf model: AppModel, in hosted: HostedWindow) -> [Placed] {
        guard let take = model.recording else { return [] }
        let title = StagePage.accessibilityTitle(for: take.mode, failedWhile: take.failedWhile, from: take.source.label.lowercased())
        guard let stage = HostedAccessibility.elements(in: hosted.host).first(where: { $0.label == title }) else { return [] }
        return HostedAccessibility.elements(in: stage.object).filter { $0.identifier?.hasSuffix("Stage.Notice") != true }.map {
            Placed(name: ($0.identifier ?? "") + "|" + ($0.label ?? ""), frame: $0.frame)
        }
    }

    @Test("a notice about the take in progress hangs on one line in the gap under the Stage's facts, and moves nothing", arguments: StageLine.allCases, StageWindow.allCases)
    @MainActor
    func stageLineMovesNothing(_ line: StageLine, _ window: StageWindow) async throws {
        let model = makeRecordingModel("stage-line-\(line.rawValue)-\(window.rawValue)")
        let wav = try tempWAV("stage-line")
        defer { try? FileManager.default.removeItem(at: wav) }
        model.installTestTake(source: .microphone, liveSource: StubSource(url: wav), startedAt: Date(timeIntervalSinceNow: -60))
        line.setUp(model)
        let hosted = HostedWindow(ContentView().environment(model), width: window.size.width, height: window.size.height)
        defer {
            hosted.close()
            model.endTestTake()
        }
        try #require(await stageCameUp(in: hosted), "the Stage never came up")
        let clear = placed(onStageOf: model, in: hosted)
        try #require(!clear.isEmpty, "the Stage's own elements never showed")

        line.post(on: model)
        let drawn = await waitUntil { draws("Stage.Notice", HostedAccessibility.elements(in: hosted.host)) }
        try #require(drawn, "the Stage has no line for it")

        let onStage = HostedAccessibility.elements(in: hosted.host)
        let shown = try #require(onStage.first { $0.identifier?.hasSuffix("Stage.Notice") == true }, "the Stage has no line for it")
        #expect(shown.value == line.message)
        #expect(placed(onStageOf: model, in: hosted) == clear, "the line moved the Stage")
        let modeLine = StageFacts.modeLine(isStreaming: false)
        let facts = try #require(onStage.first { $0.value == modeLine }).frame
        let band = try #require(onStage.first { $0.label == "Input level" }).frame
        #expect(!shown.frame.intersects(facts) && !shown.frame.intersects(band), "the line overlaps the facts or the band")
        #expect((facts.midY - shown.frame.midY) * (band.midY - shown.frame.midY) < 0, "the line is not between the facts and the band")
        #expect(!draws("ExportNotice.Button.Dismiss", onStage), "the strip came up on the Stage too")
    }

    @Test("the Stage's line gives a finishing take's stop reason first, else a notice for the take in progress that the Stage doesn't already say, and nothing else")
    func stageLineChoice() {
        var take = RecordingSession(
            takeID: 1, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: .startingCapture
        )
        _ = take.markCapturing(at: Date())
        let turnedAway = ExportNotice(message: "Finish the recording first.", failures: [], folder: nil, tone: .info, whileTakeRuns: true)
        let other = ExportNotice(message: "Auto-export couldn't write to its folder.", failures: [], folder: nil, tone: .failure)
        let reason = "The system audio stopped, so Parola stopped the recording."

        let macAudio = ExportNotice(
            message: "The system audio stopped. Your microphone is still recording.", failures: [], folder: nil, tone: .info,
            actions: [ExportNotice.Action(title: "Show", handler: .showTake(take.takeID))], whileTakeRuns: true
        )

        #expect(StageNoticeLine.shown(for: take, stopReason: nil, notice: turnedAway) == .notice(turnedAway))
        #expect(StageNoticeLine.shown(for: take, stopReason: nil, notice: other) == nil)
        #expect(StageNoticeLine.shown(for: take, stopReason: nil, notice: nil) == nil)
        #expect(StageNoticeLine.shown(for: take, stopReason: nil, notice: macAudio) == nil, "the facts' warning already says it")
        _ = take.finish(at: Date())
        #expect(StageNoticeLine.shown(for: take, stopReason: reason, notice: other) == .stopReason(reason))
        #expect(StageNoticeLine.shown(for: take, stopReason: nil, notice: turnedAway) == .notice(turnedAway))
        _ = take.transcribing(progress: 0.4)
        #expect(StageNoticeLine.shown(for: take, stopReason: reason, notice: turnedAway) == .stopReason(reason))
        take.land(entryID: "saved")
        #expect(StageNoticeLine.shown(for: take, stopReason: reason, notice: nil) == nil)
    }

    @MainActor
    private func drawsStageLine(_ hosted: HostedWindow) -> Bool {
        draws("Stage.Notice", HostedAccessibility.elements(in: hosted.host))
    }

    @Test("the Stage's line lets a notice go after its seconds; one with buttons stays up for the page after the Stage")
    @MainActor
    func stageLineExpires() async throws {
        let model = makeRecordingModel("stage-line-expiry")
        var take = RecordingSession(
            takeID: 1, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: .startingCapture
        )
        _ = take.markCapturing(at: Date())
        let hosted = HostedWindow(StageNoticeLine(take: take, shownFor: .milliseconds(200)).environment(model), width: 720, height: 40)
        defer { hosted.close() }

        model.noteRunWaitsForTake()
        let drawn = await waitUntil(timeoutMs: 1_000) { drawsStageLine(hosted) }
        #expect(drawn)
        let gone = await waitUntil(timeoutMs: 3_000) { model.exportNotice == nil }
        #expect(gone, "the notice outlived its seconds on the Stage")

        let withShow = ExportNotice(
            message: "Finish the recording first. Parola offers the recovered one again when it ends.", failures: [], folder: nil,
            tone: .info, actions: [ExportNotice.Action(title: "Show Recently Deleted", handler: .openRecentlyDeleted)], whileTakeRuns: true
        )
        model.exportNotice = withShow
        let redrawn = await waitUntil(timeoutMs: 1_000) { drawsStageLine(hosted) }
        #expect(redrawn)
        let hidden = await waitUntil(timeoutMs: 3_000) { !drawsStageLine(hosted) }
        #expect(hidden, "the line kept the notice past its seconds")
        #expect(model.exportNotice?.id == withShow.id, "a notice with buttons went before the page after the Stage")
    }
}
