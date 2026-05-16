import Foundation
import SwiftUI
import AVFoundation
import ParolaCore

extension AppModel {

    func installPlayer(for url: URL) {
        if let obs = playerTimeObserver, let player {
            player.removeTimeObserver(obs)
        }
        timeControlObserver?.invalidate()
        timeControlObserver = nil
        player?.pause()
        playerTimeObserver = nil
        let p = AVPlayer(url: url)
        player = p
        hasVideo = false
        currentTimeSeconds = 0
        isPlaying = false
        playerInstallToken &+= 1
        let token = playerInstallToken
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        playerTimeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            MainActor.assumeIsolated {
                self?.currentTimeSeconds = seconds
                self?.updateCurrentSegment(time: seconds)
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
}
