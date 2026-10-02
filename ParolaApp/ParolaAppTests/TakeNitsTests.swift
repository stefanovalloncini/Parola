import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

private func armingTake(_ arming: RecordingSession.Arming = .startingCapture) -> RecordingSession {
    RecordingSession(takeID: 1, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: arming)
}

@Suite("Ending a starting take says Cancel Recording everywhere")
struct CancelRecordingWordsTests {
    @Test("the menu bar item, the Recording menu and every other surface read Cancel Recording while the take starts")
    func words() {
        var take = armingTake(.countIn(remaining: 3))
        #expect(TakeRemote.endTitle(for: take) == "Cancel Recording")
        #expect(RecordingStatusItem.menuTitles(for: take) == ["Cancel Recording", "Pause", "Add Marker", "Discard…", "Show Parola"])
        #expect(RecordingMenuState(take: take, showsRecording: true, composerFocused: false).cancels)
        _ = take.markCapturing(at: .now)
        #expect(TakeRemote.endTitle(for: take) == "Stop Recording")
        #expect(RecordingStatusItem.menuTitles(for: take).first == "Stop Recording")
        #expect(!RecordingMenuState(take: take, showsRecording: true, composerFocused: false).cancels)
        #expect(TakeRemote.endTitle(for: nil) == "Stop Recording")
    }
}

@MainActor
@Suite("Ending a starting take cancels it, from any surface", .serialized)
struct CancelRecordingActionTests {
    private func element(_ identifier: String, in hosted: HostedWindow) -> HostedAccessibility.Element? {
        HostedAccessibility.elements(in: hosted.host).first { $0.identifier?.hasSuffix(identifier) == true }
    }

    @Test("the capsule and the pill name their button Cancel Recording while the take starts")
    func spokenWhileStarting() async throws {
        let model = makeRecordingModel("cancel-words-hosted")
        model.recordingCountInSeconds = 60
        model.startRecording(source: .microphone)
        let counting = await waitUntil { model.recording?.isCountingIn == true }
        #expect(counting)
        let take = try #require(model.recording)
        let capsule = HostedWindow(
            SessionCapsuleFace(take: take, showsMeter: false, isOnScreen: false, showStage: {}, stop: { _ in })
                .frame(maxWidth: .infinity, maxHeight: .infinity),
            width: 400, height: 120
        )
        defer { capsule.close() }
        let pill = HostedWindow(RecordingPillFace(model: model, isOnScreen: false, onShowParola: {}, onStop: { _ in }, onSize: { _ in }))
        defer { pill.close() }
        let drawn = await waitUntil { element("Toolbar.Button.SessionStop", in: capsule) != nil && element("RecordingPill.Button.Stop", in: pill) != nil }
        #expect(drawn)

        #expect(element("Toolbar.Button.SessionStop", in: capsule)?.label == "Cancel Recording")
        #expect(element("RecordingPill.Button.Stop", in: pill)?.label == "Cancel Recording")
        model.cancelRecordingCountdown()
    }

    @Test("the pill's Cancel drawn while the take started leaves it alone once it records, and ends one still starting")
    func pillActsOnWhatItDrew() async throws {
        let audio = try tempWAV("cancel-pill-drawn")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("cancel-pill-drawn")
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))

        TakeRemote.stopOrCancel(model, cancels: true)

        #expect(model.recording?.state == .recording, "the Cancel it showed never becomes a Stop")
        model.endTestTake()

        model.recordingCountInSeconds = 60
        model.startRecording(source: .microphone)
        let counting = await waitUntil { model.recordingCountdown != nil }
        #expect(counting)
        TakeRemote.stopOrCancel(model, cancels: true)
        #expect(model.recording == nil)
        #expect(model.exportNotice == nil)
    }

    @Test("the menu bar item's Cancel Recording ends a count-in, with no word")
    func statusItemCancels() async throws {
        let model = makeRecordingModel("cancel-status-item")
        model.recordingCountInSeconds = 60
        let item = RecordingStatusItem(statusBar: nil, appIsActive: { true })
        item.bind(model)
        model.startRecording(source: .microphone)
        let shown = await waitUntil { item.face?.controls.first?.title == "Cancel Recording" }
        #expect(shown)
        let control = try #require(item.face?.controls.first)

        _ = item.perform(control.action)

        #expect(model.recording == nil)
        #expect(model.recordingCountdown == nil)
    }
}

@Suite("What VoiceOver calls the Stage and its overview")
struct StageSpokenNamesTests {
    private func italian() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("the overview's label names what its value is: the run's progress, or the take's length before it")
    func overview() {
        let english = Locale(identifier: "en_US")
        let reading = TakeOverview.spoken(elapsed: 754, progress: 0.42, locale: english)
        #expect(reading.label == "Transcription progress")
        #expect(reading.value == AppFormat.percent(0.42, locale: english))
        let before = TakeOverview.spoken(elapsed: 754, progress: nil, locale: english)
        #expect(before.label == "Recording length")
        #expect(before.value == "12 minutes, 34 seconds")
    }

    @Test("the Stage reads right while it pauses and while it finishes")
    func stageTitle() throws {
        #expect(StagePage.accessibilityTitle(for: .live, from: "microphone") == "Recording from microphone")
        #expect(StagePage.accessibilityTitle(for: .paused, from: "microphone") == "Recording from microphone, paused")
        #expect(StagePage.accessibilityTitle(for: .finishing, from: "microphone") == "Finishing the recording")
        #expect(StagePage.accessibilityTitle(for: .starting, from: "microphone") == "Getting ready to record from microphone")
        let it = try italian()
        #expect(StagePage.accessibilityTitle(for: .paused, from: "microfono", bundle: it) == "Registrazione da microfono, in pausa")
        #expect(TakeOverview.spoken(elapsed: 1, progress: 0.5, bundle: it).label == "Avanzamento della trascrizione")
        #expect(TakeOverview.spoken(elapsed: 1, progress: nil, bundle: it).label == "Durata della registrazione")
    }
}
