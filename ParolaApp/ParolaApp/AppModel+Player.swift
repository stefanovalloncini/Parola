import Foundation
import SwiftUI
import AVFoundation
import ParolaCore

extension AppModel {

    func tearDownPlayer() {
        if let obs = playerTimeObserver, let player {
            player.removeTimeObserver(obs)
        }
        playerTimeObserver = nil
        timeControlObserver?.invalidate()
        timeControlObserver = nil
        player?.pause()
        player = nil
        hasVideo = false
        currentTimeSeconds = 0
        isPlaying = false
        currentSegmentID = nil
        currentWordID = nil
    }

    func installPlayer(for url: URL) {
        tearDownPlayer()
        let p = AVPlayer(url: url)
        player = p
        playerInstallToken &+= 1
        let token = playerInstallToken
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        playerTimeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            Task { @MainActor in
                self?.currentTimeSeconds = seconds
                self?.updateCurrentSegment(time: seconds)
                self?.maybeSkipSilence(currentTime: seconds)
            }
        }
        timeControlObserver = p.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in
                self?.isPlaying = playing
            }
        }
        let asset = AVURLAsset(url: url)
        Task { [weak self] in
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            guard let self, self.playerInstallToken == token else { return }
            self.hasVideo = !tracks.isEmpty
        }
    }

    private func updateCurrentSegment(time: Double) {
        guard let segments = transcript?.segments else { return }
        let match = segments.first(where: { time >= $0.start && time <= $0.end })
        if currentSegmentID != match?.id {
            currentSegmentID = match?.id
        }
        let newWordID = match?.word(at: time)?.id
        if currentWordID != newWordID {
            currentWordID = newWordID
        }
    }

    func seek(to segment: TranscriptSegment) {
        guard let player else { return }
        let t = CMTime(seconds: segment.start, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    func seekTo(chapter: Chapter) {
        guard let player else { return }
        let t = CMTime(seconds: chapter.start, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    func maybeSkipSilence(currentTime: Double) {
        guard skipSilences,
              let player,
              player.timeControlStatus == .playing,
              let segments = transcript?.segments,
              !segments.isEmpty else {
            return
        }
        guard let currentSegment = segments.first(where: { currentTime >= $0.start && currentTime <= $0.end }),
              let nextSegment = segments.first(where: { $0.start > currentSegment.end + 0.4 }) else {
            return
        }
        let gap = nextSegment.start - currentSegment.end
        guard gap >= 0.5 else { return }
        let target = CMTime(seconds: nextSegment.start, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seekTo(seconds: Double) {
        guard let player else { return }
        let t = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }
}
