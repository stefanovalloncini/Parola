import Foundation
import SwiftUI
import AVFoundation
import ParolaCore

@MainActor
@Observable
final class PlaybackController {
    private(set) var currentTime: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    private(set) var index: TranscriptIndex?
    private(set) var currentSegmentID: TranscriptSegment.ID?
    private(set) var currentWordID: WordTiming.ID?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?

    var hasAudio: Bool { player != nil }

    func load(audioURL: URL?, transcript: Transcript) {
        tearDown()
        index = TranscriptIndex(transcript: transcript)
        guard let audioURL else { return }

        let item = AVPlayerItem(url: audioURL)
        let player = AVPlayer(playerItem: item)
        self.player = player

        Task { [weak self] in
            let seconds = try? await item.asset.load(.duration).seconds
            self?.duration = seconds ?? 0
        }

        let interval = CMTime(seconds: 0.1, preferredTimescale: 1000)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(to: time.seconds.isFinite ? time.seconds : 0)
            }
        }
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func toggle() {
        guard player != nil else { return }
        isPlaying ? pause() : play()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let t = CMTime(seconds: max(0, time), preferredTimescale: 1000)
        Task { [weak self] in
            _ = await player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            self?.tick(to: time)
        }
    }

    private func tick(to time: TimeInterval) {
        currentTime = time
        let segID = index?.segmentID(at: time)
        if segID != currentSegmentID { currentSegmentID = segID }
        let wordID = index?.word(at: time)?.id
        if wordID != currentWordID { currentWordID = wordID }
    }

    #if DEBUG
    func _setCurrentTimeForTest(_ value: TimeInterval) {
        tick(to: value)
    }
    #endif

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
        currentSegmentID = nil
        currentWordID = nil
    }
}
