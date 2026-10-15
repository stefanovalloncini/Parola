import Foundation
import MediaPlayer
import ParolaCore
import ParolaSpeech
import Testing
@testable import Parola

@MainActor
@Suite("Read Aloud controller state machine")
struct ReadAloudControllerTests {
    @Test("a reading prepares, then reads unit 0 with its anchors, and pauses the app's own players first")
    func startsReading() async {
        let rig = ReadAloudRig()
        let log = PlayerLog()
        rig.players = [log.handle(playing: true)]

        await rig.start()

        #expect(rig.controller.state == .reading)
        #expect(rig.controller.item?.unitIndex == 0)
        #expect(rig.controller.item?.unitCount == 3)
        #expect(rig.controller.item?.voice == .appleAutomatic)
        #expect(rig.controller.readingAnchors.map(\.anchor) == [.segment(0)])
        #expect(rig.sink.resumeCount == 1)
        #expect(log.pauses == 1)
    }

    @Test("each finished unit moves the reading on, and the last one ends it")
    func advancesAndFinishes() async {
        let rig = ReadAloudRig()
        await rig.start(ReadAloudRig.plan(units: 2))

        await rig.finishUnit()
        await waitUntil { rig.controller.item?.unitIndex == 1 }
        #expect(rig.controller.readingAnchors.map(\.anchor) == [.segment(1)])

        await rig.finishUnit()
        await waitUntil { rig.controller.state == .idle }
        #expect(rig.controller.item == nil)
        #expect(rig.controller.readingAnchors.isEmpty)
        #expect(rig.sink.stopCount >= 1)
    }

    @Test("pause holds the output, resume plays on from the same unit")
    func pauseAndResume() async {
        let rig = ReadAloudRig()
        await rig.start()

        await rig.controller.pause()
        #expect(rig.controller.state == .paused(.user))
        #expect(rig.sink.calls.contains(.pause(fade: true)))
        #expect(rig.controller.readingOwnsKeys)

        let resumed = await rig.controller.resume()
        #expect(resumed)
        #expect(rig.controller.state == .reading)
        #expect(rig.sink.resumeCount == 2)
        #expect(rig.controller.item?.unitIndex == 0)
    }

    @Test("skip goes to the next sentence and back to the previous one")
    func skips() async {
        let rig = ReadAloudRig()
        await rig.start()

        await rig.controller.skip(by: 1)
        await waitUntil { rig.controller.item?.unitIndex == 1 }
        await rig.controller.skip(by: -1)
        await waitUntil { rig.controller.item?.unitIndex == 0 }
        #expect(rig.controller.state == .reading)
    }

    @Test("stop clears the reading and lets go of the output")
    func stops() async {
        let rig = ReadAloudRig()
        await rig.start()

        await rig.controller.stop()

        #expect(rig.controller.state == .idle)
        #expect(rig.controller.item == nil)
        #expect(rig.sink.stopCount >= 1)
        #expect(!rig.controller.readingOwnsKeys)
    }

    @Test("a new reading stops the old session before the new one plays")
    func replacementStopsFirst() async {
        let rig = ReadAloudRig()
        await rig.start(ReadAloudRig.plan(entryID: "first"))
        let before = rig.sink.calls.count

        await rig.controller.start(ReadAloudRig.plan(entryID: "second"))
        await waitUntil { rig.controller.state == .reading && rig.controller.item?.entryID == "second" }

        let after = Array(rig.sink.calls[before...])
        let stop = after.firstIndex(of: .stop)
        let subscribe = after.firstIndex(of: .subscribe)
        #expect(stop != nil && subscribe != nil && stop! < subscribe!)
    }

    @Test("a new reading waits for the old session's stop to finish before it subscribes to the output")
    func replacementWaitsForTheStop() async throws {
        let log = SpeechEventLog()
        let rig = ReadAloudRig(events: log.observer, gatesCancel: true)
        let gate = try #require(rig.cancelGate)
        await rig.renderer.holdStart()
        let first = Task { await rig.controller.start(ReadAloudRig.plan(entryID: "first")) }
        await waitUntil { log.events.contains(.held(unitID: 0)) }
        await first.value
        await gate.holdCancel()
        let subscribes = rig.sink.calls.filter { $0 == .subscribe }.count

        let second = Task { await rig.controller.start(ReadAloudRig.plan(entryID: "second")) }
        await waitUntil { await gate.cancelCalls > 0 }
        await settle()
        #expect(rig.sink.calls.filter { $0 == .subscribe }.count == subscribes)

        await gate.releaseCancel()
        await rig.renderer.releaseStart()
        await second.value
        #expect(rig.sink.calls.filter { $0 == .subscribe }.count > subscribes)
        await rig.controller.stop()
    }

    @Test("a start that finds the reading blocked reads nothing, publishes nothing and never resumes the output")
    func startWhileBlocked() async {
        let rig = ReadAloudRig()
        rig.blocked = .take

        await rig.controller.start(ReadAloudRig.plan())
        await settle()

        #expect(rig.controller.state == .idle)
        #expect(rig.controller.item == nil)
        #expect(!rig.nowPlaying.isPublished)
        #expect(rig.sink.resumeCount == 0)
        #expect(rig.sink.scheduledCount == 0)

        rig.blocked = nil
        rig.controller.focusChanged()
        await settle()
        #expect(rig.sink.scheduledCount == 0)
    }

    @Test("a resume that finds the reading blocked once its await returns plays nothing")
    func resumeRacingABlock() async {
        let rig = ReadAloudRig()
        await rig.start()
        await rig.controller.pause()
        let resumes = rig.sink.resumeCount
        rig.blockedFromRead = rig.blockedReads + 2

        let resumed = await rig.controller.resume()

        #expect(!resumed)
        #expect(rig.controller.state == .paused(.user))
        #expect(rig.sink.resumeCount == resumes)
    }

    @Test("a language with no voice reads nothing and says so")
    func noVoice() async {
        let rig = ReadAloudRig(languages: ["en"])

        await rig.controller.start(ReadAloudRig.plan(language: "fa"))

        #expect(rig.controller.state == .noVoice("fa"))
        #expect(rig.sink.scheduledCount == 0)
        #expect(rig.nowPlaying.publications.last?.isPlaying != true || !rig.nowPlaying.isPublished)
    }

    @Test("the base language picks the voice: en-GB reads with an English voice")
    func baseLanguageMatches() async {
        let rig = ReadAloudRig(languages: ["en"])

        await rig.start(ReadAloudRig.plan(language: "en-GB"))

        #expect(rig.controller.state == .reading)
    }

    @Test("a renderer that fails ends in failed, and try again restarts from that unit")
    func failureAndRetry() async {
        let rig = ReadAloudRig(failAtUnit: 1)
        await rig.start()

        await rig.finishUnit()
        await waitUntil { rig.controller.state.name == "failed" }
        #expect(rig.controller.item?.unitIndex == 1)
        #expect(!rig.nowPlaying.isPublished)

        await rig.renderer.setFailAtUnit(nil)
        await rig.controller.retry()
        await waitUntil { rig.controller.state == .reading }
        #expect(rig.controller.state == .reading)
        #expect(rig.controller.item?.unitIndex == 1)
    }

    @Test("speed reaches the output, and a value outside the five falls back to 1")
    func speed() async {
        let rig = ReadAloudRig()
        await rig.start()

        rig.controller.setSpeed(1.5)
        await waitUntil { rig.sink.speed == 1.5 }
        rig.controller.setSpeed(3)
        #expect(rig.controller.speed == 1)
    }

    @Test("a reading owns the keys while it plays or waits, and while paused for anything but media")
    func keyOwnership() async {
        let rig = ReadAloudRig()
        #expect(!rig.controller.readingOwnsKeys)
        await rig.start()
        #expect(rig.controller.readingOwnsKeys)

        rig.controller.mediaStartedPlaying()
        await waitUntil { rig.controller.state == .paused(.media) }
        #expect(!rig.controller.readingOwnsKeys)
    }

    @Test("a reading is of one entry and one source")
    func readsMatching() async {
        let rig = ReadAloudRig()
        await rig.start(ReadAloudRig.plan(entryID: "a", source: .transcript(fromSegment: 4)))

        #expect(rig.controller.reads(entryID: "a", source: .transcript(fromSegment: nil)))
        #expect(!rig.controller.reads(entryID: "a", source: .summary))
        #expect(!rig.controller.reads(entryID: "b", source: .transcript(fromSegment: nil)))
        #expect(!rig.controller.reads(entryID: "a", source: .translation(language: "it")))
    }

    @Test("deleting the entry being read stops it; another entry leaves it alone")
    func entryRemoval() async {
        let rig = ReadAloudRig()
        await rig.start(ReadAloudRig.plan(entryID: "a"))

        rig.controller.entryRemoved("b")
        #expect(rig.controller.state == .reading)
        rig.controller.entryRemoved("a")
        await waitUntil { rig.controller.state == .idle }
    }

    @Test("the intro appearing stops the reading")
    func introStops() async {
        let rig = ReadAloudRig()
        await rig.start()

        rig.introShown = true
        rig.controller.focusChanged()
        await waitUntil { rig.controller.state == .idle }
    }

    @Test("quitting stops the output and withdraws Now Playing without waiting")
    func terminates() async {
        let rig = ReadAloudRig()
        await rig.start()
        let stops = rig.sink.stopCount

        rig.controller.terminate()

        #expect(rig.controller.state == .idle)
        #expect(rig.sink.stopCount == stops + 1)
        #expect(!rig.nowPlaying.isPublished)
    }
}

@MainActor
final class PlayerLog {
    private(set) var pauses = 0

    func handle(playing: Bool) -> PlayerHandle {
        PlayerHandle(
            id: ObjectIdentifier(self),
            isPlaying: { playing },
            pause: { [self] in pauses += 1 },
            resume: {}
        )
    }
}
