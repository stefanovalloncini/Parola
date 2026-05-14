import Foundation
import SwiftUI
import AVFoundation
import ParolaCore

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var index: TranscriptIndex?

    private var player: AVPlayer?
    private var timeObserver: Any?

    func load(audioURL: URL, transcript: Transcript) {
        tearDown()
        index = TranscriptIndex(transcript: transcript)

        let item = AVPlayerItem(url: audioURL)
        let player = AVPlayer(playerItem: item)
        self.player = player

        Task { [weak self] in
            let seconds = try? await item.asset.load(.duration).seconds
            await MainActor.run { self?.duration = seconds ?? 0 }
        }

        let interval = CMTime(seconds: 0.03, preferredTimescale: 1000)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = time.seconds.isFinite ? time.seconds : 0
        }
    }

    func play() {
        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let t = CMTime(seconds: max(0, time), preferredTimescale: 1000)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.currentTime = time
        }
    }

    func currentSegmentID() -> TranscriptSegment.ID? {
        index?.segmentID(at: currentTime)
    }

    func currentWord() -> WordTiming? {
        index?.word(at: currentTime)
    }

    func _setCurrentTimeForTest(_ value: TimeInterval) {
        currentTime = value
    }

    private func tearDown() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }
}
