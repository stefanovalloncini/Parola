import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
private final class Calls {
    var count = 0
}

private func failedTake(_ id: Int = 1) -> RecordingSession {
    var take = RecordingSession(takeID: id, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: .startingCapture)
    take.fail("The microphone stopped.")
    return take
}

@Suite("A failure out of sight")
struct OutOfSightFailureTests {
    @Test("a failure that came while Parola was in the background is held until Parola is in front, then never again")
    func heldUntilFront() {
        var failure = OutOfSightFailure()
        let take = failedTake()
        let inBackground = failure.holds(take, appActive: false)
        #expect(inBackground)
        let inFrontAgain = failure.holds(take, appActive: true)
        #expect(inFrontAgain, "held until Parola comes to the front, not just while it isn't")
        failure.release()
        let afterFront = failure.holds(take, appActive: false)
        #expect(!afterFront, "once seen, it stays seen")
    }

    @Test("a failure that came with Parola in front is never held, even once Parola goes to the background")
    func seenFailureNeverHeld() {
        var failure = OutOfSightFailure()
        let take = failedTake()
        let inFront = failure.holds(take, appActive: true)
        #expect(!inFront)
        let laterInBackground = failure.holds(take, appActive: false)
        #expect(!laterInBackground)
    }

    @Test("a running take, a dismissed failure or the next take lets the hold go")
    func letGo() {
        var failure = OutOfSightFailure()
        let first = failure.holds(failedTake(1), appActive: false)
        #expect(first)
        let dismissed = failure.holds(nil, appActive: false)
        #expect(!dismissed)
        #expect(failure.held == nil)
        let next = failure.holds(failedTake(2), appActive: false)
        #expect(next, "the next failure is weighed on its own")
        var running = RecordingSession(takeID: 3, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: .startingCapture)
        running.markCapturing(at: .now)
        let recording = failure.holds(running, appActive: false)
        #expect(!recording)
        #expect(failure.held == nil)
    }
}

@Suite("The menu bar item for a failed take")
struct StoppedStatusItemTests {
    @Test("a failed take reads Stopped behind a warning sign, says why first in its menu, and offers only Show Parola")
    @MainActor
    func stoppedFace() {
        let take = failedTake()
        let face = RecordingStatusItem.face(for: take, now: .now)
        #expect(face.clock == "Stopped")
        #expect(face.lamp == .stopped)
        #expect(face.spoken == "Recording stopped: The microphone stopped.")
        #expect(face.notice == "The microphone stopped.")
        #expect(face.controls.map(\.title) == ["Show Parola"])

        let menu = RecordingStatusItem.menu(face.controls, notice: face.notice, target: nil)
        #expect(menu.items.map { $0.isSeparatorItem ? "—" : $0.title } == ["The microphone stopped.", "—", "Show Parola"])
        #expect(menu.items.first?.isEnabled == false)
    }

    @Test("a long reason shows its first sentence in the menu, and the whole of it in the tooltip")
    @MainActor
    func longReason() {
        let reason = "Microphone access is off. Turn it on in System Settings, then start recording again."
        let menu = RecordingStatusItem.menu([], notice: reason, target: nil)
        #expect(menu.items.first?.title == "Microphone access is off.")
        #expect(menu.items.first?.toolTip == reason)
        #expect(RecordingStatusItem.firstSentence(of: "No period here") == "No period here")
    }

    @Test("the warning sign is a symbol in the warning colour, not the recording dot")
    func stoppedGlyph() {
        let title = RecordingStatusItem.attributedTitle(clock: "Stopped", lamp: .stopped)
        #expect(title.string.hasSuffix(" Stopped"))
        #expect(title.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)
        #expect(!title.string.contains("●"))
    }

    @Test("the stopped words read in Italian")
    func italian() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let it = try #require(Bundle(path: path))
        #expect(TakeRemote.stoppedTitle(bundle: it) == "Interrotta")
        #expect(TakeRemote.stoppedStatus("Il microfono si è fermato.", bundle: it) == "Registrazione interrotta: Il microfono si è fermato.")
    }
}

@MainActor
@Suite("A take that fails out of sight", .serialized)
struct TakeFailsOutOfSightTests {
    @Test("a count-in that fails with Parola in the background stays on the pill and in the menu bar as stopped, until Parola is in front")
    func countInFailureStays() async throws {
        let model = makeRecordingModel("out-of-sight-count-in")
        model.recordingCountInSeconds = 60
        let pill = RecordingPill(makesPanel: false)
        pill.bind(model, appActive: false)
        let item = RecordingStatusItem(statusBar: nil, appIsActive: { false })
        item.bind(model)
        model.startRecording(source: .microphone)
        let up = await waitUntil { pill.isShown && item.face != nil }
        #expect(up)

        model.failCountIn("Parola can't use the microphone.")

        let stopped = await waitUntil { item.face?.lamp == .stopped }
        #expect(stopped)
        #expect(pill.isShown, "the take failed and the pill went away without a word")
        #expect(item.face?.notice == "Parola can't use the microphone.")

        pill.appActiveChanged(true)
        item.appBecameActive()
        let gone = await waitUntil { !pill.isShown && item.face == nil }
        #expect(gone)
        pill.appActiveChanged(false)
        await settle()
        #expect(!pill.isShown, "a failure seen once doesn't come back")
        model.forgetTakeSession()
    }

    @Test("a failure dismissed on its Stage takes the stopped pill and menu bar item with it")
    func dismissedFailureGoes() async throws {
        let model = makeRecordingModel("out-of-sight-dismissed")
        model.recordingCountInSeconds = 60
        let pill = RecordingPill(makesPanel: false)
        pill.bind(model, appActive: false)
        let item = RecordingStatusItem(statusBar: nil, appIsActive: { false })
        item.bind(model)
        model.startRecording(source: .microphone)
        let up = await waitUntil { pill.isShown && item.face != nil }
        #expect(up)
        model.failCountIn("Parola can't use the microphone.")
        let stopped = await waitUntil { item.face?.lamp == .stopped }
        #expect(stopped)

        model.dismissTakeFailure()

        let gone = await waitUntil { !pill.isShown && item.face == nil }
        #expect(gone)
    }

    @Test("a take that fails with Parola in front leaves the menu bar as before")
    func failureInFrontLeaves() async throws {
        let model = makeRecordingModel("out-of-sight-in-front")
        model.recordingCountInSeconds = 60
        let item = RecordingStatusItem(statusBar: nil, appIsActive: { true })
        item.bind(model)
        model.startRecording(source: .microphone)
        let up = await waitUntil { item.face != nil }
        #expect(up)

        model.failCountIn("Parola can't use the microphone.")

        let gone = await waitUntil { item.face == nil }
        #expect(gone)
        model.forgetTakeSession()
    }

    @Test("a take that fails in the background bounces the Dock icon once; one that fails in front doesn't")
    func dockBounce() async throws {
        for active in [false, true] {
            let model = makeRecordingModel("out-of-sight-dock-\(active)")
            model.recordingCountInSeconds = 60
            let calls = Calls()
            let badge = DockBadge(show: { _ in }, appIsActive: { active }, requestAttention: { calls.count += 1 })
            badge.bind(model)
            model.startRecording(source: .microphone)
            let counting = await waitUntil { model.recordingCountdown != nil }
            #expect(counting)

            model.failCountIn("Parola can't use the microphone.")
            await settle(for: .milliseconds(300))
            model.updateSession(of: model.recording?.takeID) { $0.title = "Renamed" }
            await settle(for: .milliseconds(100))

            #expect(calls.count == (active ? 0 : 1), "active \(active)")
            model.forgetTakeSession()
            withExtendedLifetime(badge) {}
        }
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("A live take that fails out of sight", .serialized)
    struct LiveTakeFailsOutOfSightTests {
        @Test("a live take whose stream fails mid-take stays on the pill and in the menu bar as stopped")
        func liveFailureStays() async throws {
            try await withMocksCleared([.streaming]) {
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "words")],
                    partials: ["w", "wo", "words"],
                    delayMs: 1_500,
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "The microphone stopped.")
                ))
                let model = makeRecordingModel("out-of-sight-live")
                model.useStreaming = true
                model.selectedModel = "openai_whisper-tiny"
                let pill = RecordingPill(makesPanel: false)
                pill.bind(model, appActive: false)
                let item = RecordingStatusItem(statusBar: nil, appIsActive: { false })
                item.bind(model)
                model.startRecording(source: .microphone)
                let up = await waitUntil(timeoutMs: 30_000) { model.recording?.state == .recording && pill.isShown }
                #expect(up)
                let failed = await waitUntil(timeoutMs: 15_000) { item.face?.lamp == .stopped }
                #expect(failed)
                let shown = pill.isShown
                #expect(shown, "the live take failed and the pill went away without a word")
                _ = await waitUntil(timeoutMs: 10_000) { !model.hasPendingTakeWork }
            }
        }
    }
}

@MainActor
@Suite("The take's warnings outside the window", .serialized)
struct TakeWarningsOutsideTests {
    @Test("low disk space comes before silence, and a take that isn't running warns of nothing")
    func whichWarning() throws {
        let audio = try tempWAV("warning-order")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("warning-order")
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        let take = try #require(model.recording)
        #expect(TakeRemote.warning(for: take, in: model) == nil)

        model.recordingIsSilent = true
        #expect(TakeRemote.warning(for: take, in: model)?.message == "No voice detected — check your microphone.")
        model.recordingDiskSpaceLow = true
        #expect(TakeRemote.warning(for: take, in: model)?.symbol == "internaldrive")
        #expect(TakeRemote.warning(for: failedTake(), in: model) == nil)
        model.endTestTake()
    }

    @Test("the menu bar item's menu says the warning first, on a line that does nothing, and VoiceOver hears it")
    func statusItemWarns() async throws {
        let audio = try tempWAV("warning-status-item")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("warning-status-item")
        let item = RecordingStatusItem(statusBar: nil, appIsActive: { false })
        item.bind(model)
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        let shown = await waitUntil { item.face != nil }
        #expect(shown)
        #expect(item.face?.notice == nil)

        model.recordingIsSilent = true

        let warned = await waitUntil { item.face?.notice == "No voice detected — check your microphone." }
        #expect(warned)
        let spoken = item.face?.spoken ?? ""
        #expect(spoken.hasSuffix(". No voice detected — check your microphone."))
        let face = try #require(item.face)
        let menu = RecordingStatusItem.menu(face.controls, notice: face.notice, target: nil)
        #expect(menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
            == ["No voice detected — check your microphone.", "Stop Recording", "Pause", "Add Marker", "Discard…", "—", "Show Parola"])
        #expect(menu.items.first?.isEnabled == false)

        model.recordingIsSilent = false
        let cleared = await waitUntil { item.face?.notice == nil }
        #expect(cleared)
        model.endTestTake()
    }

    @Test("the pill rings in amber with the warning, which its help and VoiceOver value carry")
    func pillWarns() async throws {
        let audio = try tempWAV("warning-pill")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("warning-pill")
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        let pill = HostedWindow(RecordingPillFace(model: model, isOnScreen: false, onShowParola: {}, onStop: { _ in }, onSize: { _ in }))
        defer { pill.close() }
        func showParola() -> HostedAccessibility.Element? {
            HostedAccessibility.elements(in: pill.host).first { $0.identifier == "RecordingPill.Button.ShowParola" }
        }
        #expect(showParola()?.value ?? "" == "")

        model.recordingDiskSpaceLow = true

        let warned = await waitUntil { showParola()?.value == "Low disk space — recording stops automatically below 200 MB." }
        #expect(warned)
        model.endTestTake()
    }
}
