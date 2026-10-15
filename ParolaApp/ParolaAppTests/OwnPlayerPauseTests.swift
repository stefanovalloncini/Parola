import AVFoundation
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Own player pause")
struct OwnPlayerPauseTests {
    @MainActor private final class FakePlayer {
        var isPlaying: Bool
        private(set) var pauseCount = 0
        private(set) var resumeCount = 0

        init(isPlaying: Bool) { self.isPlaying = isPlaying }

        var handle: PlayerHandle {
            PlayerHandle(
                id: ObjectIdentifier(self),
                isPlaying: { [weak self] in self?.isPlaying ?? false },
                pause: { [weak self] in self?.pauseCount += 1; self?.isPlaying = false },
                resume: { [weak self] in self?.resumeCount += 1; self?.isPlaying = true }
            )
        }
    }

    @Test("only the players that were playing are paused, and only those are played again")
    func pausesOnlyWhatPlays() async {
        let playing = FakePlayer(isPlaying: true)
        let idle = FakePlayer(isPlaying: false)
        let pause = OwnPlayerPause { [playing.handle, idle.handle] }

        #expect(await pause.pausePlaying() == true)
        #expect(playing.pauseCount == 1)
        #expect(idle.pauseCount == 0)

        await pause.resumePaused()
        #expect(playing.resumeCount == 1)
        #expect(idle.resumeCount == 0)

        await pause.resumePaused()
        #expect(playing.resumeCount == 1)
    }

    @Test("a player closed or replaced during the take is not played again")
    func droppedPlayerStaysPaused() async {
        let closed = FakePlayer(isPlaying: true)
        let kept = FakePlayer(isPlaying: true)
        let listed = Listed([closed.handle, kept.handle])
        let pause = OwnPlayerPause { listed.handles }

        #expect(await pause.pausePlaying() == true)
        listed.handles = [kept.handle]
        await pause.resumePaused()
        #expect(closed.resumeCount == 0)
        #expect(kept.resumeCount == 1)
    }

    @MainActor private final class Listed {
        var handles: [PlayerHandle]
        init(_ handles: [PlayerHandle]) { self.handles = handles }
    }

    @Test("nothing playing means nothing paused and nothing to resume")
    func nothingPlaying() async {
        let idle = FakePlayer(isPlaying: false)
        let pause = OwnPlayerPause { [idle.handle] }
        #expect(await pause.pausePlaying() == false)
        await pause.resumePaused()
        #expect(idle.resumeCount == 0)
    }

    @Test("a take with pause-media on pauses a playing transcript player and plays it again at the end")
    func mediaSessionDrivesIt() async {
        let playing = FakePlayer(isPlaying: true)
        let session = MediaSession(
            muter: nil, player: SilentToggler(), ownPlayback: OwnPlayerPause { [playing.handle] }
        )
        await session.enterRecording(config: MediaSessionConfig(muteSystemAudio: false, pausePlayback: true), holder: .take)
        #expect(playing.isPlaying == false)
        await session.exitRecording(holder: .take)
        #expect(playing.isPlaying == true)
    }

    @Test("the model offers its main player and every open window's player")
    func modelPlayers() async throws {
        let model = EntryWindowTestSupport.makeModel("ownplayers")
        #expect(model.ownPlayers().isEmpty)
        model.player = AVPlayer()
        #expect(model.ownPlayers().count == 1)

        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha"], speakers: [nil], audio: try EntryWindowTestSupport.silentAudioFile()
        )
        let session = await EntryWindowTestSupport.openSession(model, entry)
        let windowPlayer = try #require(session.player)
        let ids = Set(model.ownPlayers().map(\.id))
        #expect(ids.count == 2)
        #expect(ids.contains(ObjectIdentifier(windowPlayer)))
    }

    private struct SilentToggler: MediaPlaybackToggler {
        func pause() async {}
        func play() async {}
        func isPlaying() async -> Bool { false }
    }
}
