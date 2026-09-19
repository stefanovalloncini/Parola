import AVFoundation
import Foundation

/// Plays the introduction's demo clip; its `currentTime` is the only clock the reveal runs on.
@MainActor
@Observable
final class DemoPlayer {
    private let player: AVAudioPlayer
    private let listener = FinishListener()

    private(set) var isPlaying = false
    private(set) var isFinished = false

    var isMuted = false {
        didSet { player.volume = isMuted ? 0 : 1 }
    }

    // AVAudioPlayer rewinds to 0 as it ends, a turn before the delegate says so.
    var currentTime: Double { isPlaying && !player.isPlaying ? player.duration : player.currentTime }
    var volume: Float { player.volume }

    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        player.delegate = listener
        player.prepareToPlay()
        listener.onFinish = { [weak self] in
            self?.isPlaying = false
            self?.isFinished = true
        }
    }

    func play() {
        isFinished = false
        player.currentTime = 0
        isPlaying = player.play()
    }

    func replay() {
        play()
    }

    func stop() {
        player.stop()
        player.currentTime = 0
        isPlaying = false
    }
}

/// The clip and its player, owned by the stage so walking back into the scene does not start the voice again.
@MainActor
@Observable
final class DemoPlayback {
    private static let bundledClip = DemoClip.bundled()

    let script = DemoPlayback.bundledClip?.script ?? .placeholder
    let player: DemoPlayer?
    private(set) var hasPlayed = false

    /// The reveal has run and is not running now, so the card shows the whole transcript and Replay.
    var isSettled: Bool { hasPlayed && !(player?.isPlaying ?? false) }
    var autoplays: Bool { Self.autoplays(hasPlayed: hasPlayed, hasPlayer: player != nil) }

    /// The first visit plays the clip; coming back to the scene leaves the transcript where it stopped.
    static func autoplays(hasPlayed: Bool, hasPlayer: Bool) -> Bool { hasPlayer && !hasPlayed }

    init() {
        player = DemoPlayback.bundledClip.flatMap { try? DemoPlayer(url: $0.audioURL) }
    }

    func start() {
        guard let player else { return }
        hasPlayed = true
        player.play()
    }

    func stop() {
        player?.stop()
    }
}

private final class FinishListener: NSObject, AVAudioPlayerDelegate {
    var onFinish: (@MainActor @Sendable () -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard let onFinish else { return }
        Task { @MainActor in onFinish() }
    }
}
