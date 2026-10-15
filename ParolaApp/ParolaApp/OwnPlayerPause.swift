import AVFoundation
import ParolaCore

struct PlayerHandle {
    let isPlaying: @MainActor () -> Bool
    let pause: @MainActor () -> Void
    let resume: @MainActor () -> Void

    @MainActor
    init(_ player: AVPlayer) {
        isPlaying = { player.timeControlStatus != .paused }
        pause = { player.pause() }
        resume = { player.play() }
    }

    init(isPlaying: @escaping @MainActor () -> Bool, pause: @escaping @MainActor () -> Void, resume: @escaping @MainActor () -> Void) {
        self.isPlaying = isPlaying
        self.pause = pause
        self.resume = resume
    }
}

/// Pauses the transcript players that are playing when a take or dictation starts, and plays those again when it ends.
@MainActor
final class OwnPlayerPause: OwnPlaybackControl {
    private let players: @MainActor () -> [PlayerHandle]
    private var paused: [PlayerHandle] = []

    init(players: @escaping @MainActor () -> [PlayerHandle]) {
        self.players = players
    }

    func pausePlaying() async -> Bool {
        paused = players().filter { $0.isPlaying() }
        for player in paused { player.pause() }
        return !paused.isEmpty
    }

    func resumePaused() async {
        let toResume = paused
        paused = []
        for player in toResume { player.resume() }
    }
}
