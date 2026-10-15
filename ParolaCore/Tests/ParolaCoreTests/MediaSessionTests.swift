import Foundation
import Testing
@testable import ParolaCore

@Suite("Media session")
struct MediaSessionTests {

    private actor SpyMuter: SystemAudioMuter {
        var startMuted: Bool
        private(set) var current: Bool
        private(set) var setMutedCalls: [Bool] = []
        private(set) var queryCalls = 0

        init(startMuted: Bool) {
            self.startMuted = startMuted
            self.current = startMuted
        }

        func isMuted() async -> Bool {
            queryCalls += 1
            return current
        }

        func setMuted(_ muted: Bool) async {
            setMutedCalls.append(muted)
            current = muted
        }
    }

    private actor SpyPlayer: MediaPlaybackToggler {
        private(set) var pauseCalls = 0
        private(set) var playCalls = 0

        func pause() async { pauseCalls += 1 }
        func play() async { playCalls += 1 }
    }

    private actor SpyOwnPlayback: OwnPlaybackControl {
        let pausesSomething: Bool
        private(set) var pauseCalls = 0
        private(set) var resumeCalls = 0

        init(pausesSomething: Bool) { self.pausesSomething = pausesSomething }

        func pausePlaying() async -> Bool {
            pauseCalls += 1
            return pausesSomething
        }

        func resumePaused() async { resumeCalls += 1 }
    }

    @Test("with pause on, the app's own playback is paused at the start and resumed at the end")
    func ownPlaybackPausesAndResumes() async {
        let own = SpyOwnPlayback(pausesSomething: true)
        let session = MediaSession(muter: SpyMuter(startMuted: false), player: SpyPlayer(), ownPlayback: own)

        await session.enterRecording(config: MediaSessionConfig(muteSystemAudio: false, pausePlayback: true))
        #expect(await own.pauseCalls == 1)
        #expect(await own.resumeCalls == 0)
        await session.exitRecording()
        #expect(await own.resumeCalls == 1)
    }

    @Test("with pause off, or when nothing of the app's own was playing, nothing is resumed")
    func ownPlaybackLeftAlone() async {
        let own = SpyOwnPlayback(pausesSomething: false)
        let session = MediaSession(muter: SpyMuter(startMuted: false), player: SpyPlayer(), ownPlayback: own)

        await session.enterRecording(config: MediaSessionConfig(muteSystemAudio: true, pausePlayback: false))
        await session.exitRecording()
        await session.enterRecording(config: MediaSessionConfig(muteSystemAudio: false, pausePlayback: true))
        await session.exitRecording()
        #expect(await own.pauseCalls == 1)
        #expect(await own.resumeCalls == 0)
    }

    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var arrivals = 0
        private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

        func pass() async {
            arrivals += 1
            for waiter in arrivalWaiters { waiter.resume() }
            arrivalWaiters.removeAll()
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func waitForArrival() async {
            guard arrivals == 0 else { return }
            await withCheckedContinuation { arrivalWaiters.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    private actor SlowOwnPlayback: OwnPlaybackControl {
        let gate = Gate()
        private(set) var resumeCalls = 0

        func pausePlaying() async -> Bool {
            await gate.pass()
            return true
        }

        func resumePaused() async { resumeCalls += 1 }
    }

    @Test("a take and a dictation share one pause: the first to end leaves it in place")
    func overlappingHoldersKeepThePause() async {
        let muter = SpyMuter(startMuted: false)
        let player = SpyPlayer()
        let own = SpyOwnPlayback(pausesSomething: true)
        let session = MediaSession(muter: muter, player: player, ownPlayback: own)
        let config = MediaSessionConfig(muteSystemAudio: true, pausePlayback: true)

        await session.enterRecording(config: config)
        await session.enterRecording(config: config)
        #expect(await muter.setMutedCalls == [true])
        #expect(await own.pauseCalls == 1)

        await session.exitRecording()
        #expect(await muter.setMutedCalls == [true])
        #expect(await own.resumeCalls == 0)
        #expect(await player.playCalls == 0)

        await session.exitRecording()
        #expect(await muter.setMutedCalls == [true, false])
        #expect(await own.resumeCalls == 1)
        #expect(await player.playCalls == 1)
    }

    @Test("an exit while a start is still pausing undoes what the start does afterwards")
    func exitDuringEnter() async {
        let muter = SpyMuter(startMuted: false)
        let player = SpyPlayer()
        let own = SlowOwnPlayback()
        let session = MediaSession(muter: muter, player: player, ownPlayback: own)
        let config = MediaSessionConfig(muteSystemAudio: true, pausePlayback: true)

        let entering = Task { await session.enterRecording(config: config) }
        await own.gate.waitForArrival()
        await session.exitRecording()
        await own.gate.open()
        await entering.value

        #expect(await muter.current == false)
        #expect(await own.resumeCalls == 1)
        #expect(await player.pauseCalls == 0)

        await session.enterRecording(config: config)
        await session.exitRecording()
        #expect(await own.resumeCalls == 2)
    }

    @Test("both flags on mutes and pauses once")
    func enterWithBothFlags() async {
        let muter = SpyMuter(startMuted: false)
        let player = SpyPlayer()
        let session = MediaSession(muter: muter, player: player)

        await session.enterRecording(config: MediaSessionConfig(muteSystemAudio: true, pausePlayback: true))

        let setCalls = await muter.setMutedCalls
        let pauseCalls = await player.pauseCalls
        #expect(setCalls == [true])
        #expect(pauseCalls == 1)
    }

    @Test("pause-only does not touch mute")
    func enterPauseOnly() async {
        let muter = SpyMuter(startMuted: false)
        let player = SpyPlayer()
        let session = MediaSession(muter: muter, player: player)

        await session.enterRecording(config: MediaSessionConfig(muteSystemAudio: false, pausePlayback: true))

        let setCalls = await muter.setMutedCalls
        let queries = await muter.queryCalls
        let pauseCalls = await player.pauseCalls
        #expect(setCalls.isEmpty)
        #expect(queries == 0)
        #expect(pauseCalls == 1)
    }

    @Test("mute-only does not touch playback")
    func enterMuteOnly() async {
        let muter = SpyMuter(startMuted: false)
        let player = SpyPlayer()
        let session = MediaSession(muter: muter, player: player)

        await session.enterRecording(config: MediaSessionConfig(muteSystemAudio: true, pausePlayback: false))

        let setCalls = await muter.setMutedCalls
        let pauseCalls = await player.pauseCalls
        #expect(setCalls == [true])
        #expect(pauseCalls == 0)
    }

    @Test("exit restores unmute and sends play")
    func exitRestoresBoth() async {
        let muter = SpyMuter(startMuted: false)
        let player = SpyPlayer()
        let session = MediaSession(muter: muter, player: player)

        await session.enterRecording(config: MediaSessionConfig(muteSystemAudio: true, pausePlayback: true))
        await session.exitRecording()

        let setCalls = await muter.setMutedCalls
        let playCalls = await player.playCalls
        #expect(setCalls == [true, false])
        #expect(playCalls == 1)
    }

    @Test("exit leaves pre-existing mute alone")
    func exitPreservesUserMute() async {
        let muter = SpyMuter(startMuted: true)
        let player = SpyPlayer()
        let session = MediaSession(muter: muter, player: player)

        await session.enterRecording(config: MediaSessionConfig(muteSystemAudio: true, pausePlayback: false))
        await session.exitRecording()

        let setCalls = await muter.setMutedCalls
        #expect(setCalls.isEmpty)
    }

    @Test("second enter without exit is a no-op")
    func reentryIsNoOp() async {
        let muter = SpyMuter(startMuted: false)
        let player = SpyPlayer()
        let session = MediaSession(muter: muter, player: player)

        await session.enterRecording(config: MediaSessionConfig(muteSystemAudio: true, pausePlayback: true))
        await session.enterRecording(config: MediaSessionConfig(muteSystemAudio: true, pausePlayback: true))

        let setCalls = await muter.setMutedCalls
        let pauseCalls = await player.pauseCalls
        #expect(setCalls == [true])
        #expect(pauseCalls == 1)
    }

    @Test("exit without enter is safe")
    func exitWithoutEnter() async {
        let muter = SpyMuter(startMuted: false)
        let player = SpyPlayer()
        let session = MediaSession(muter: muter, player: player)

        await session.exitRecording()

        let setCalls = await muter.setMutedCalls
        let playCalls = await player.playCalls
        #expect(setCalls.isEmpty)
        #expect(playCalls == 0)
    }
}
