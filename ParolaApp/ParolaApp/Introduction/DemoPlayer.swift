import AVFoundation
import Foundation

/// Plays the introduction's demo clip. The scene reads `currentTime` to drive the reveal, so the
/// audio is the clock and nothing else has to keep time.
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

    var currentTime: Double { player.currentTime }
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

private final class FinishListener: NSObject, AVAudioPlayerDelegate {
    var onFinish: (@MainActor @Sendable () -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard let onFinish else { return }
        Task { @MainActor in onFinish() }
    }
}
