import Foundation
import MediaPlayer
import ParolaCore
import ParolaSpeech
import Testing
@testable import Parola

@MainActor
@Suite("Read Aloud Now Playing")
struct ReadAloudNowPlayingTests {
    @Test("a reading publishes its source, entry and sentence count while it plays")
    func publishesWhilePlaying() async {
        let rig = ReadAloudRig()

        await rig.start(ReadAloudRig.plan(source: .summary, title: "Weekly sync"))

        let last = rig.nowPlaying.publications.last
        #expect(last?.title == "Summary · Weekly sync")
        #expect(last?.unitCount == 3)
        #expect(last?.isPlaying == true)
        #expect(rig.nowPlaying.publications.first?.isPlaying == true)
    }

    @Test("the sentence number follows the reading")
    func followsUnits() async {
        let rig = ReadAloudRig()
        await rig.start()

        await rig.finishUnit()
        await waitUntil { rig.nowPlaying.publications.last?.unitIndex == 1 }
    }

    @Test("a user pause keeps it published as paused; resuming publishes playing again")
    func userPauseStaysPublished() async {
        let rig = ReadAloudRig()
        await rig.start()

        await rig.controller.pause()
        #expect(rig.nowPlaying.isPublished)
        #expect(rig.nowPlaying.publications.last?.isPlaying == false)

        await rig.controller.resume()
        #expect(rig.nowPlaying.publications.last?.isPlaying == true)
    }

    @Test("sleep, a session switch and an output change keep it published; take, dictation, captions and media withdraw it")
    func publicationByPauseReason() async {
        for (reason, published) in [
            (ReadAloudController.PauseReason.sleep, true), (.sessionInactive, true), (.outputChanged, true),
            (.take, false), (.dictation, false), (.captions, false), (.media, false),
        ] {
            let rig = ReadAloudRig()
            await rig.start()

            await rig.controller.yield(to: reason)

            #expect(rig.nowPlaying.isPublished == published, "\(reason)")
        }
    }

    @Test("stop, the end of the script, a failure and a missing voice all withdraw it")
    func withdraws() async {
        let stopped = ReadAloudRig()
        await stopped.start()
        await stopped.controller.stop()
        #expect(!stopped.nowPlaying.isPublished)

        let ended = ReadAloudRig()
        await ended.start(ReadAloudRig.plan(units: 1))
        await ended.finishUnit()
        await waitUntil { ended.controller.state == .idle }
        #expect(!ended.nowPlaying.isPublished)

        let failed = ReadAloudRig(failAtUnit: 0)
        await failed.controller.start(ReadAloudRig.plan())
        await waitUntil { failed.controller.state.name == "failed" }
        #expect(!failed.nowPlaying.isPublished)

        let mute = ReadAloudRig(languages: ["en"])
        await mute.controller.start(ReadAloudRig.plan(language: "fa"))
        #expect(!mute.nowPlaying.isPublished)
        #expect(mute.nowPlaying.publications.isEmpty)

        let intro = ReadAloudRig()
        await intro.start()
        intro.introShown = true
        intro.controller.focusChanged()
        await waitUntil { !intro.nowPlaying.isPublished }
    }

    @Test("play, pause, toggle and the skip keys drive the reading")
    func remoteCommands() async {
        let rig = ReadAloudRig()
        await rig.start()

        rig.nowPlaying.fire(.pause)
        await waitUntil { rig.controller.state == .paused(.user) }
        rig.nowPlaying.fire(.play)
        await waitUntil { rig.controller.state == .reading }
        rig.nowPlaying.fire(.toggle)
        await waitUntil { rig.controller.state == .paused(.user) }
        rig.nowPlaying.fire(.toggle)
        await waitUntil { rig.controller.state == .reading }
        rig.nowPlaying.fire(.next)
        await waitUntil { rig.controller.item?.unitIndex == 1 }
        rig.nowPlaying.fire(.previous)
        await waitUntil { rig.controller.item?.unitIndex == 0 }
    }

    @Test("play is refused while blocked and for two seconds after the block ends")
    func refusesAroundABlock() async {
        let rig = ReadAloudRig()
        await rig.start()
        await rig.controller.pause()

        rig.blocked = .dictation
        rig.controller.focusChanged()
        await waitUntil { rig.controller.state == .paused(.dictation) }
        #expect(rig.controller.handle(.play) == .commandFailed)

        rig.blocked = nil
        rig.controller.focusChanged()
        #expect(rig.controller.handle(.play) == .commandFailed)
        #expect(rig.controller.handle(.next) == .commandFailed)

        await waitUntil { rig.clock.sleeperCount == 1 }
        rig.clock.advance(by: .seconds(1.9))
        #expect(rig.controller.handle(.play) == .commandFailed)
        rig.clock.advance(by: .seconds(0.2))
        await waitUntil { !rig.controller.isInRefusalWindow }

        #expect(rig.controller.handle(.play) == .success)
        await waitUntil { rig.controller.state == .reading }
    }

    @Test("with nothing reading, a key finds no item")
    func noItem() {
        let rig = ReadAloudRig()
        #expect(rig.controller.handle(.play) == .noActionableNowPlayingItem)
    }
}
