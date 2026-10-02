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
    take.markCapturing(at: .now)
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

    @Test("a transcription that fails after Stop isn't held by the pill or the menu bar item; the Dock still counts it")
    func transcriptionFailureNotHeld() {
        var take = RecordingSession(takeID: 1, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: .startingCapture)
        take.markCapturing(at: .now)
        take.finish(at: .now)
        take.transcribing(progress: nil)
        take.fail("Transcription failed: the engine stopped.")
        var surface = OutOfSightFailure()
        let surfaceHolds = surface.holds(take, appActive: false)
        #expect(!surfaceHolds)
        var dock = OutOfSightFailure(includesTranscription: true)
        let dockHolds = dock.holds(take, appActive: false)
        #expect(dockHolds)
    }

    @Test("a take that stopped on its own is held like a failed one, weighed once, and a running one never is")
    func stoppedOnItsOwnHeld() {
        var take = RecordingSession(takeID: 1, source: .systemAudio, category: .meeting, title: "R", isStreaming: false, arming: .startingCapture)
        take.markCapturing(at: .now)
        take.finish(at: .now)
        take.land(entryID: "E")
        var surface = OutOfSightFailure()
        let asked = surface.holds(take, appActive: false)
        #expect(!asked, "a take that landed after a Stop isn't held")
        let ownStop = surface.holds(take, stoppedOnItsOwn: true, appActive: false)
        #expect(ownStop)
        var inFront = OutOfSightFailure()
        let seen = inFront.holds(take, stoppedOnItsOwn: true, appActive: true)
        #expect(!seen)
    }

    @Test("a failure after a take's stop on its own is weighed on its own: a stop seen in front doesn't hide a failure that comes once Parola is behind")
    func failureAfterAStopWeighedAgain() {
        var take = RecordingSession(takeID: 1, source: .systemAudio, category: .meeting, title: "R", isStreaming: false, arming: .startingCapture)
        take.markCapturing(at: .now)
        take.finish(at: .now)
        var surface = OutOfSightFailure()
        var dock = OutOfSightFailure(includesTranscription: true)
        let surfaceSawStop = surface.holds(take, stoppedOnItsOwn: true, appActive: true)
        let dockSawStop = dock.holds(take, stoppedOnItsOwn: true, appActive: true)
        #expect(!surfaceSawStop && !dockSawStop)
        var cutShort = take
        cutShort.fail("Parola couldn't keep writing the recording to disk.")
        let surfaceHoldsCut = surface.holds(cutShort, stoppedOnItsOwn: true, appActive: false)
        let dockHoldsCut = dock.holds(cutShort, stoppedOnItsOwn: true, appActive: false)
        #expect(surfaceHoldsCut && dockHoldsCut)
        let stillHeld = surface.holds(cutShort, stoppedOnItsOwn: true, appActive: false)
        #expect(stillHeld, "weighed once: the same ending doesn't weigh again")
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

    @Test("a take that stopped on its own says why in its notice's words, once it has stopped; a failure in its banner's")
    func endings() {
        var take = RecordingSession(takeID: 1, source: .systemAudio, category: .meeting, title: "R", isStreaming: false, arming: .startingCapture)
        take.markCapturing(at: .now)
        let reason = AppModel.macAudioStoppedTakeMessage()
        #expect(TakeRemote.ending(of: take, stopReason: reason) == nil, "still recording")
        take.finish(at: .now)
        #expect(TakeRemote.ending(of: take, stopReason: reason) == nil, "still finishing")
        take.land(entryID: "E")
        #expect(TakeRemote.ending(of: take, stopReason: reason) == TakeRemote.Ending(reason: reason, spoken: reason))
        #expect(TakeRemote.ending(of: take, stopReason: nil) == nil)
        let face = RecordingStatusItem.face(for: take, now: .now, stopReason: reason)
        #expect(face.clock == "Stopped")
        #expect(face.notice == reason)
        #expect(face.spoken == reason)
        #expect(face.controls.map(\.title) == ["Show Parola"])
        let failed = failedTake()
        #expect(TakeRemote.ending(of: failed, stopReason: nil)?.spoken == "Recording stopped: The microphone stopped.")
        #expect(TakeRemote.ending(of: failed, stopReason: reason)?.reason == "The microphone stopped.", "the recording's own failure says more than the stop")
        var untranscribed = RecordingSession(takeID: 2, source: .systemAudio, category: .meeting, title: "R", isStreaming: false, arming: .startingCapture)
        untranscribed.markCapturing(at: .now)
        untranscribed.finish(at: .now)
        untranscribed.transcribing(progress: nil)
        untranscribed.fail("Transcription failed: the engine stopped.")
        #expect(TakeRemote.ending(of: untranscribed, stopReason: reason)?.reason == reason, "a transcription's failure leaves the stop to say why")
    }

    @Test("the stopped words read in Italian")
    func italian() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let it = try #require(Bundle(path: path))
        #expect(TakeRemote.stoppedTitle(bundle: it) == "Interrotta")
        #expect(TakeRemote.failureStatus("Il microfono si è fermato.", failedWhile: .recording, bundle: it) == "Registrazione interrotta: Il microfono si è fermato.")
        #expect(TakeRemote.failureStatus("Accesso negato.", failedWhile: .starting, bundle: it) == "Avvio della registrazione non riuscito: Accesso negato.")
    }
}

@MainActor
@Suite("A take that fails out of sight", .serialized)
struct TakeFailsOutOfSightTests {
    @Test("a count-in that fails with Parola in the background stays on the pill and in the menu bar as stopped, until Parola is in front")
    func countInFailureStays() async throws {
        let model = makeRecordingModel("out-of-sight-count-in")
        model.recordingCountInSeconds = 60
        let pill = RecordingPill(makesPanel: false, appIsActive: { false })
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
        let pill = RecordingPill(makesPanel: false, appIsActive: { false })
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
            if active {
                await settle(for: .milliseconds(300))
            } else {
                let bounced = await waitUntil { calls.count == 1 }
                #expect(bounced)
            }
            model.updateSession(of: model.recording?.takeID) { $0.title = "Renamed" }
            await settle(for: .milliseconds(100))

            #expect(calls.count == (active ? 0 : 1), "active \(active)")
            model.forgetTakeSession()
            withExtendedLifetime(badge) {}
        }
    }

    @Test("the pill weighs a failure by whether Parola is in front, as the menu bar item and the Dock do, not by its own last word on it")
    func pillWeighsLikeTheOthers() async throws {
        let model = makeRecordingModel("out-of-sight-pill-source")
        model.recordingCountInSeconds = 60
        let pill = RecordingPill(makesPanel: false, appIsActive: { true })
        pill.bind(model, appActive: false)
        let item = RecordingStatusItem(statusBar: nil, appIsActive: { true })
        item.bind(model)
        model.startRecording(source: .microphone)
        let up = await waitUntil { pill.isShown && item.face != nil }
        #expect(up)

        model.failCountIn("Parola can't use the microphone.")

        let itemGone = await waitUntil { item.face == nil }
        #expect(itemGone)
        let pillGone = await waitUntil { !pill.isShown }
        #expect(pillGone, "the pill held a failure the menu bar item let go, for the same take")
        model.forgetTakeSession()
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("A transcription that fails out of sight", .serialized)
    struct TranscriptionFailsOutOfSightTests {
        @Test("a take stopped in the background whose transcription then fails doesn't come back as stopped on the pill or in the menu bar, and the Dock bounces once")
        func transcriptionFailureStaysOff() async throws {
            let audio = try makeTakeWAV("out-of-sight-transcription", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "the engine stopped"),
                    gate: gate
                ))
                let model = makeRecordingModel("out-of-sight-transcription")
                let pill = RecordingPill(makesPanel: false, appIsActive: { false })
                pill.bind(model, appActive: false)
                let item = RecordingStatusItem(statusBar: nil, appIsActive: { false })
                item.bind(model)
                let bounces = Calls()
                let badge = DockBadge(show: { _ in }, appIsActive: { false }, requestAttention: { bounces.count += 1 })
                badge.bind(model)

                recordAndStop(model, audio: audio, seconds: 1)
                let transcribing = await waitUntil { model.recording?.isTranscribing == true && !pill.isShown && item.face == nil }
                #expect(transcribing)
                await gate.open()
                let failed = await waitUntil { model.recording?.failedWhile == .transcribing }
                #expect(failed)
                let bounced = await waitUntil { bounces.count == 1 }
                #expect(bounced, "a transcript that failed in the background still asks for a look")
                await settle(for: .milliseconds(300))

                let pillShown = pill.isShown
                let itemFace = item.face
                #expect(!pillShown, "the pill came back as stopped for a transcription that failed")
                #expect(itemFace == nil, "the menu bar item came back as stopped for a transcription that failed")
                #expect(bounces.count == 1)
                withExtendedLifetime(badge) {}
            }
        }
    }

    @MainActor
    @Suite("A take that stops on its own out of sight", .serialized)
    struct TakeStopsOnItsOwnOutOfSightTests {
        @Test("a take that stops on its own with Parola in the background stays on the pill and in the menu bar as stopped, in its notice's words, and the Dock bounces once")
        func heldAsStopped() async throws {
            let audio = try makeTakeWAV("out-of-sight-on-its-own", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "the Mac side")])
                let model = makeRecordingModel("out-of-sight-on-its-own")
                model.useStreaming = false
                let pill = RecordingPill(makesPanel: false, appIsActive: { false })
                pill.bind(model, appActive: false)
                let item = RecordingStatusItem(statusBar: nil, appIsActive: { false })
                item.bind(model)
                let bounces = Calls()
                let badge = DockBadge(show: { _ in }, appIsActive: { false }, requestAttention: { bounces.count += 1 })
                badge.bind(model)
                model.installTestTake(source: .systemAudio, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -1))
                let take = try #require(model.recording?.takeID)
                let reason = AppModel.macAudioStoppedTakeMessage()

                model.stopTakeOnItsOwn(take, saying: reason)

                let landed = await landedEntry(model)
                #expect(landed != nil, "it was saved")
                let stopped = await waitUntil { item.face?.lamp == .stopped }
                #expect(stopped)
                #expect(item.face?.notice == reason)
                #expect(item.face?.spoken == reason)
                let pillShown = pill.isShown
                #expect(pillShown, "the take stopped on its own and the pill went away without a word")
                let face = HostedWindow(RecordingPillFace(model: model, isOnScreen: false, onShowParola: {}, onStop: { _ in }, onSize: { _ in }))
                defer { face.close() }
                await settle(for: .milliseconds(100))
                let label = HostedAccessibility.elements(in: face.host).first { $0.identifier == "RecordingPill.Label.Stopped" }?.label
                #expect(label == reason)
                let bounced = await waitUntil { bounces.count == 1 }
                #expect(bounced)

                pill.appActiveChanged(true)
                item.appBecameActive()
                let gone = await waitUntil { !pill.isShown && item.face == nil }
                #expect(gone)
                #expect(bounces.count == 1)
                withExtendedLifetime(badge) {}
            }
        }

        @Test("with Parola in front, a take that stops on its own leaves the pill and the menu bar as a Stop does, with no bounce")
        func inFrontLetsGo() async throws {
            let audio = try makeTakeWAV("out-of-sight-on-its-own-front", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "the Mac side")])
                let model = makeRecordingModel("out-of-sight-on-its-own-front")
                model.useStreaming = false
                let item = RecordingStatusItem(statusBar: nil, appIsActive: { true })
                item.bind(model)
                let bounces = Calls()
                let badge = DockBadge(show: { _ in }, appIsActive: { true }, requestAttention: { bounces.count += 1 })
                badge.bind(model)
                model.installTestTake(source: .systemAudio, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -1))
                let take = try #require(model.recording?.takeID)

                model.stopTakeOnItsOwn(take, saying: AppModel.macAudioStoppedTakeMessage())

                let landed = await landedEntry(model)
                #expect(landed != nil)
                let gone = await waitUntil { item.face == nil }
                #expect(gone)
                #expect(bounces.count == 0)
                withExtendedLifetime(badge) {}
            }
        }
    }

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
                let pill = RecordingPill(makesPanel: false, appIsActive: { false })
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

@MainActor
@Suite("A meeting's Mac audio that stopped, outside the window", .serialized)
struct MacAudioStoppedOutsideTests {
    @Test("while your microphone records on, the stopped Mac audio warns on the pill, in the menu bar and on the Stage, after low disk space")
    func warns() async throws {
        let audio = try tempWAV("mac-stopped-warning")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("mac-stopped-warning")
        let item = RecordingStatusItem(statusBar: nil, appIsActive: { false })
        item.bind(model)
        model.installTestTake(source: .systemAudio, liveSource: StubSource(url: audio))
        let shown = await waitUntil { item.face != nil }
        #expect(shown)
        let pill = HostedWindow(RecordingPillFace(model: model, isOnScreen: false, onShowParola: {}, onStop: { _ in }, onSize: { _ in }))
        defer { pill.close() }
        let take = try #require(model.recording)
        // Stretched, or the window shrinks to the line and its next line has nowhere to go.
        let stage = HostedWindow(
            StageFacts(take: take, isOnScreen: false).environment(model).frame(maxWidth: .infinity, maxHeight: .infinity),
            width: 900, height: 160
        )
        defer { stage.close() }
        func pillValue() -> String? {
            HostedAccessibility.elements(in: pill.host).first { $0.identifier == "RecordingPill.Button.ShowParola" }?.value
        }

        model.takeMacAudioStopped = true

        let inMenu = await waitUntil { item.face?.notice == "Mac audio stopped" }
        #expect(inMenu)
        #expect(TakeRemote.warning(for: take, in: model)?.symbol == "waveform.slash")
        let onPill = await waitUntil { pillValue() == "Mac audio stopped" }
        #expect(onPill)
        let onStage = await waitUntil { HostedAccessibility.words(in: stage.host).contains("Mac audio stopped") }
        #expect(onStage)
        model.recordingDiskSpaceLow = true
        #expect(TakeRemote.warning(for: take, in: model)?.symbol == "internaldrive", "low disk space ends the take, so it comes first")
        model.endTestTake()
    }

    @Test("the Mac audio stopping while your microphone records on bounces the Dock once with Parola in the background, never in front")
    func asksForALookOnce() async throws {
        for active in [false, true] {
            let audio = try tempWAV("mac-stopped-attention-\(active)")
            defer { try? FileManager.default.removeItem(at: audio) }
            let model = makeRecordingModel("mac-stopped-attention-\(active)")
            let asks = Calls()
            let badge = DockBadge(show: { _ in }, appIsActive: { active }, requestAttention: { asks.count += 1 })
            badge.bind(model)
            model.installTestTake(source: .systemAudio, liveSource: StubSource(url: audio))
            await settle(for: .milliseconds(100))
            #expect(asks.count == 0)

            model.takeMacAudioStopped = true

            if active {
                await settle(for: .milliseconds(300))
            } else {
                let asked = await waitUntil { asks.count == 1 }
                #expect(asked)
            }
            model.updateSession(of: model.recording?.takeID) { $0.title = "Renamed" }
            #expect(model.pauseTake())
            #expect(model.resumeTake())
            await settle(for: .milliseconds(200))
            #expect(asks.count == (active ? 0 : 1), "active \(active)")
            model.endTestTake()
            withExtendedLifetime(badge) {}
        }
    }

    @Test("a Mac capture that stopped once the take had stopped asks for no look of its own")
    func noLookOnceStopped() async throws {
        let audio = try tempWAV("mac-stopped-after-stop")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("mac-stopped-after-stop")
        let asks = Calls()
        let badge = DockBadge(show: { _ in }, appIsActive: { false }, requestAttention: { asks.count += 1 })
        badge.bind(model)
        model.installTestTake(source: .systemAudio, liveSource: StubSource(url: audio))
        model.updateSession(of: model.recording?.takeID) { $0.finish(at: .now) }

        model.takeMacAudioStopped = true

        await settle(for: .milliseconds(300))
        #expect(asks.count == 0)
        model.endTestTake()
        withExtendedLifetime(badge) {}
    }

    @Test("once the take stops, a stopped Mac capture warns of nothing, since it is what ended the take")
    func noWarningOnceStopped() throws {
        let model = makeRecordingModel("mac-stopped-finishing")
        model.takeMacAudioStopped = true
        var take = RecordingSession(takeID: 1, source: .systemAudio, category: .meeting, title: "R", isStreaming: false, arming: .startingCapture)
        take.markCapturing(at: .now)
        #expect(TakeRemote.warning(for: take, in: model)?.message == "Mac audio stopped")
        take.finish(at: .now)
        #expect(TakeRemote.warning(for: take, in: model) == nil)
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        #expect(String(localized: "Mac audio stopped", bundle: italian) == "Audio del Mac fermato")
    }
}

private func unfoldableNotice() -> ExportNotice {
    ExportNotice(
        message: AppModel.micTrackUnfoldableMessage(title: "Weekly sync"), failures: [], folder: nil, tone: .failure,
        actions: [ExportNotice.Action(title: "Reveal in Finder", handler: .revealFile(URL(fileURLWithPath: "/tmp/parola-mic.wav")))]
    )
}

/// Whether the test's Parola is the app in front.
@MainActor
private final class Front {
    var active = true
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("A failure that follows a take's stop, out of sight", .serialized)
    struct FailureAfterAStopTests {
        enum Stop: String, CaseIterable, Sendable {
            case user
            case onItsOwnSeenInFront
        }

        enum LaterFailure: String, CaseIterable, Sendable {
            case transcription
            case save
        }

        @Test(
            "a failure that comes once Parola is behind bounces the Dock once, whether the take stopped by Stop or on its own in front; a save failure holds the pill and the menu bar item too, a transcription failure doesn't",
            arguments: Stop.allCases, LaterFailure.allCases
        )
        func laterFailure(stop: Stop, failure: LaterFailure) async throws {
            let audio = try makeTakeWAV("later-failure-\(stop.rawValue)-\(failure.rawValue)", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "the engine stopped"),
                    gate: gate
                ))
                let model = makeRecordingModel("later-failure-\(stop.rawValue)-\(failure.rawValue)")
                model.useStreaming = false
                let front = Front()
                let pill = RecordingPill(makesPanel: false, appIsActive: { front.active })
                pill.bind(model, appActive: true)
                let item = RecordingStatusItem(statusBar: nil, appIsActive: { front.active })
                item.bind(model)
                let bounces = Calls()
                let badge = DockBadge(show: { _ in }, appIsActive: { front.active }, requestAttention: { bounces.count += 1 })
                badge.bind(model)
                let capture = HeldCutShortCapture(file: audio)
                let source: any LiveAudioSource = failure == .save ? capture : StubSource(url: audio)
                model.installTestTake(source: .systemAudio, liveSource: source, startedAt: Date(timeIntervalSinceNow: -1))
                let take = try #require(model.recording?.takeID)

                switch stop {
                case .user: model.stopRecordingAndTranscribe()
                case .onItsOwnSeenInFront: model.stopTakeOnItsOwn(take, saying: AppModel.macAudioStoppedTakeMessage())
                }
                // The surfaces weigh the stop on the main actor's next turns, while Parola is still in front.
                await settle(for: .milliseconds(200))
                front.active = false
                pill.appActiveChanged(false)
                switch failure {
                case .transcription: await gate.open()
                case .save: await capture.letGo()
                }

                let failed = await waitUntil {
                    if case .failed = model.recording?.state { return true }
                    return false
                }
                #expect(failed)
                let bounced = await waitUntil { bounces.count == 1 }
                #expect(bounced, "a failure out of sight asks for a look")
                if failure == .save {
                    let held = await waitUntil { pill.isShown && item.face?.lamp == .stopped }
                    #expect(held, "a save failure holds the pill and the menu bar item")
                } else {
                    await settle(for: .milliseconds(200))
                    let pillShown = pill.isShown
                    let itemFace = item.face
                    #expect(!pillShown && itemFace == nil, "a transcription failure doesn't bring them back")
                }
                #expect(bounces.count == 1)
                _ = await waitUntil { !model.hasPendingTakeWork }
                withExtendedLifetime(badge) {}
            }
        }

        @Test("a stop on its own out of sight and a save failure that follows while Parola is still behind are one ending: one bounce")
        func oneBouncePerUnseenEnding() async throws {
            let audio = try makeTakeWAV("later-failure-unseen", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                let model = makeRecordingModel("later-failure-unseen")
                model.useStreaming = false
                let bounces = Calls()
                let badge = DockBadge(show: { _ in }, appIsActive: { false }, requestAttention: { bounces.count += 1 })
                badge.bind(model)
                let capture = HeldCutShortCapture(file: audio)
                model.installTestTake(source: .systemAudio, liveSource: capture, startedAt: Date(timeIntervalSinceNow: -1))
                let take = try #require(model.recording?.takeID)

                model.stopTakeOnItsOwn(take, saying: AppModel.macAudioStoppedTakeMessage())
                let bounced = await waitUntil { bounces.count == 1 }
                #expect(bounced)
                await capture.letGo()
                let failed = await waitUntil {
                    if case .failed = model.recording?.state { return true }
                    return false
                }
                #expect(failed)
                await settle(for: .milliseconds(200))

                #expect(bounces.count == 1)
                _ = await waitUntil { !model.hasPendingTakeWork }
                withExtendedLifetime(badge) {}
            }
        }
    }

    @MainActor
    @Suite("A failure notice a Mac-audio notice covers", .serialized)
    struct CoveredFailureNoticeTests {
        @Test("a take that stops on its own covers an unrelated failure notice, which comes back once its notice is dismissed, once")
        func comesBackOnce() async throws {
            let audio = try makeTakeWAV("covered-notice", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "the Mac side")])
                let model = makeRecordingModel("covered-notice")
                model.useStreaming = false
                let unfoldable = unfoldableNotice()
                model.exportNotice = unfoldable
                model.installTestTake(source: .systemAudio, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -1))
                let take = try #require(model.recording?.takeID)

                model.stopTakeOnItsOwn(take, saying: AppModel.macAudioStoppedTakeMessage())

                #expect(model.exportNotice?.message == AppModel.macAudioStoppedTakeMessage())
                model.dismissExportNotice()
                #expect(model.exportNotice?.id == unfoldable.id, "the Reveal in Finder notice came back")
                model.dismissExportNotice()
                #expect(model.exportNotice == nil, "one deep, never a queue")
                _ = await landedEntry(model)
            }
        }

        @Test("resetTestState forgets a notice waiting under a Mac-audio notice, so nothing from before the reset comes back")
        func resetForgetsIt() async throws {
            let model = makeRecordingModel("covered-notice-reset")
            let server = try ParolaAutomationServer(model: model)
            let context = AutomationContext(model: model, server: server)
            let lifecycle = Dictionary(uniqueKeysWithValues: server.lifecycleCommands().map { ($0.name, $0) })
            let reset = try #require(lifecycle["resetTestState"])
            model.noticeUnderMacAudio = unfoldableNotice()

            _ = try await reset.handler(try reset.validate(AutomationArgs([:])), context)

            #expect(model.noticeUnderMacAudio == nil)
            withExtendedLifetime(server) {}
        }

        @Test("an info notice, or a failure about the same take, isn't brought back")
        func onlyAnUnrelatedFailure() async throws {
            let audio = try makeTakeWAV("covered-notice-not", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "the Mac side")])
                let model = makeRecordingModel("covered-notice-not")
                model.useStreaming = false
                model.installTestTake(source: .systemAudio, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -1))
                let take = try #require(model.recording?.takeID)
                model.exportNotice = ExportNotice(message: "Finish the recording first.", failures: [], folder: nil, tone: .info)

                model.stopTakeOnItsOwn(take, saying: AppModel.macAudioStoppedTakeMessage())
                model.dismissExportNotice()

                #expect(model.exportNotice == nil)
                _ = await landedEntry(model)
                model.exportNotice = ExportNotice(message: "About this take", failures: [], folder: nil, tone: .failure, forTake: take)
                model.keepCoveredFailure(model.exportNotice, take: take)
                #expect(model.noticeUnderMacAudio == nil)
            }
        }
    }
}
