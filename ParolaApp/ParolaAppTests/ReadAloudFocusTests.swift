import AppKit
import AVFAudio
import Foundation
import ParolaCore
import os
import ParolaSpeech
import Testing
@testable import Parola

@MainActor
@Suite("Read Aloud focus hooks")
struct ReadAloudFocusTests {
    @Test("the Mac going to sleep pauses the reading; waking and the display sleeping do not touch it")
    func sleepPausesWakeDoesNot() async {
        let rig = ReadAloudRig()
        await rig.start()

        rig.systemCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        rig.systemCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await settle()
        #expect(rig.controller.state == .reading)

        rig.systemCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await waitUntil { rig.controller.state == .paused(.sleep) }
        await waitUntil { rig.sink.calls.contains(.pause(fade: false)) }

        rig.systemCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await settle()
        #expect(rig.controller.state == .paused(.sleep))
    }

    @Test("switching account pauses the reading")
    func sessionResignPauses() async {
        let rig = ReadAloudRig()
        await rig.start()

        rig.systemCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)

        await waitUntil { rig.controller.state == .paused(.sessionInactive) }
    }

    @Test("the output ending its stream pauses the reading, and resume plays on")
    func outputChangePauses() async {
        let rig = ReadAloudRig()
        await rig.start()

        rig.sink.simulateOutputChange()

        await waitUntil { rig.controller.state == .paused(.outputChanged) }
        let resumed = await rig.controller.resume()
        #expect(resumed)
        #expect(rig.controller.state == .reading)
    }

    @Test("a device monitor firing on the real offline output pauses the reading")
    func monitorPausesTheOfflineOutput() async throws {
        let monitor = FakeDeviceMonitor()
        let output = try ReadAloudOutput(offline: true, monitor: monitor)
        let rig = ReadAloudRig(output: output)
        await rig.start()

        monitor.simulateChange()

        await waitUntil { rig.controller.state == .paused(.outputChanged) }
        #expect(rig.controller.state == .paused(.outputChanged))
    }

    @Test("a player starting pauses the reading as media, and keeps a paused one paused")
    func mediaYields() async {
        let rig = ReadAloudRig()
        await rig.start()

        rig.controller.mediaStartedPlaying()
        await waitUntil { rig.controller.state == .paused(.media) }
        #expect(!rig.nowPlaying.isPublished)

        await rig.controller.start(ReadAloudRig.plan(entryID: "other"))
        await waitUntil { rig.controller.state == .reading }
        await rig.controller.pause()
        rig.controller.mediaStartedPlaying()
        #expect(rig.controller.state == .paused(.media))
    }

    @Test("take, dictation and captions each pause the reading with their own reason")
    func focusYields() async {
        for reason in [ReadAloudController.PauseReason.take, .dictation, .captions] {
            let rig = ReadAloudRig()
            await rig.start()

            await rig.controller.yield(to: reason)

            #expect(rig.controller.state == .paused(reason))
            #expect(rig.sink.calls.contains(.pause(fade: false)))
            #expect(!rig.nowPlaying.isPublished)
        }
    }

    @Test("a yield on a reading already paused changes its reason and keeps it paused")
    func yieldOnPaused() async {
        let rig = ReadAloudRig()
        await rig.start()
        await rig.controller.pause()
        #expect(rig.nowPlaying.isPublished)

        await rig.controller.yield(to: .take)

        #expect(rig.controller.state == .paused(.take))
        #expect(!rig.nowPlaying.isPublished)
    }

    @Test("nothing to yield when nothing reads")
    func yieldWhenIdle() async {
        let rig = ReadAloudRig()
        await rig.controller.yield(to: .take)
        #expect(rig.controller.state == .idle)
    }

    @Test("a blocking take pauses the reading and never resumes it by itself")
    func blockingNeverResumes() async {
        let rig = ReadAloudRig()
        await rig.start()

        rig.blocked = .take
        rig.controller.focusChanged()
        await waitUntil { rig.controller.state == .paused(.take) }
        #expect(await rig.controller.resume() == false)
        #expect(rig.controller.readingBlockedReason == .take)

        rig.blocked = nil
        rig.controller.focusChanged()
        await settle()
        #expect(rig.controller.state == .paused(.take))
        #expect(await rig.controller.resume())
        #expect(rig.controller.state == .reading)
    }

    @Test("a reading still preparing when a take starts never schedules a buffer")
    func preparingNeverSchedules() async {
        let log = SpeechEventLog()
        let rig = ReadAloudRig(events: log.observer)
        await rig.renderer.holdPrewarm()
        let starting = Task { await rig.controller.start(ReadAloudRig.plan()) }
        await waitUntil { log.events.contains(.prewarmHeld) }
        #expect(rig.controller.state == .preparing)

        rig.blocked = .take
        rig.controller.focusChanged()
        await rig.controller.yield(to: .take)
        await rig.renderer.releasePrewarm()
        await starting.value

        #expect(rig.controller.state == .paused(.take))
        #expect(rig.sink.scheduledCount == 0)
        #expect(rig.sink.resumeCount == 0)

        rig.blocked = nil
        rig.controller.focusChanged()
        #expect(await rig.controller.resume())
        await waitUntil { rig.controller.state == .reading }
        await waitUntil { rig.sink.scheduledCount > 0 }
    }

    @Test("a block tells the session, so a unit that finishes rendering during it schedules nothing until resume")
    func blockStopsScheduling() async {
        let log = SpeechEventLog()
        let rig = ReadAloudRig(events: log.observer)
        await rig.renderer.holdStart()
        let starting = Task { await rig.controller.start(ReadAloudRig.plan()) }
        await waitUntil { log.events.contains(.held(unitID: 0)) }

        rig.blocked = .take
        rig.controller.focusChanged()
        await waitUntil { rig.controller.state == .paused(.take) }
        await rig.renderer.releaseStart()
        await starting.value
        await settle()
        #expect(rig.sink.scheduledCount == 0)

        rig.blocked = nil
        rig.controller.focusChanged()
        #expect(await rig.controller.resume())
        await waitUntil { rig.sink.scheduledCount > 0 }
    }

    @Test("a take while reading with media pausing on leaves the reader paused after the take exits")
    func readerStaysPausedAfterMediaExit() async {
        let rig = ReadAloudRig()
        await rig.start()
        let other = OtherApp()
        let media = MediaSession(muter: other, player: other)

        await rig.controller.yield(to: .take)
        await media.enterRecording(config: MediaSessionConfig(muteSystemAudio: false, pausePlayback: true), holder: .take)
        await media.exitRecording(holder: .take)

        #expect(other.plays == 1)
        #expect(rig.controller.state == .paused(.take))
        #expect(rig.sink.resumeCount == 1)
    }

    @Test("a dictation while the reader is paused leaves it paused after the dictation exits")
    func pausedReaderStaysPausedAfterDictation() async {
        let rig = ReadAloudRig()
        await rig.start()
        await rig.controller.pause()
        let other = OtherApp()
        let media = MediaSession(muter: other, player: other)

        await rig.controller.yield(to: .dictation)
        await media.enterRecording(config: MediaSessionConfig(muteSystemAudio: false, pausePlayback: true), holder: .dictation)
        await media.exitRecording(holder: .dictation)

        #expect(other.plays == 1)
        #expect(rig.controller.state == .paused(.dictation))
    }

    @Test("a voice list change and the app becoming active refresh the voices")
    func refreshesVoices() async {
        let center = NotificationCenter()
        var refreshes = 0
        let controller = ReadAloudController(environment: ReadAloudEnvironment(
            renderer: { MockSpeechRenderer() },
            sink: { FakeReadAloudSink() },
            nowPlaying: { RecordingNowPlaying() },
            refreshVoices: { refreshes += 1 },
            systemNotifications: { NotificationCenter() },
            appNotifications: center,
            clock: ContinuousClock(),
            mockVoice: nil
        ))

        center.post(name: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        #expect(refreshes == 2)
        withExtendedLifetime(controller) {}
    }
}

private final class OtherApp: SystemAudioMuter, MediaPlaybackToggler, Sendable {
    private let played = OSAllocatedUnfairLock(initialState: 0)
    var plays: Int { played.withLock { $0 } }

    func isMuted() async -> Bool { false }
    func setMuted(_ muted: Bool) async {}
    func pause() async {}
    func play() async { played.withLock { $0 += 1 } }
    func isPlaying() async -> Bool { true }
}
