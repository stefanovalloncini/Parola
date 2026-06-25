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
        pendingMediaDuration = nil
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
            let assetDuration = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
            guard let self, self.playerInstallToken == token else { return }
            self.hasVideo = !tracks.isEmpty
            if let assetDuration, assetDuration.isFinite, assetDuration > 0 {
                self.pendingMediaDuration = assetDuration
                if var t = self.transcript, (t.durationSeconds ?? 0) < assetDuration - 0.05 {
                    t.durationSeconds = assetDuration
                    self.transcript = t
                }
            }
        }
    }

    func updateCurrentSegment(time: Double) {
        guard let segments = transcript?.segments else { return }
        let match: TranscriptSegment?
        if let cached = currentSegmentID,
           let idx = segments.firstIndex(where: { $0.id == cached }),
           time >= segments[idx].start && time <= segments[idx].end {
            match = segments[idx]
        } else {
            match = segments.binarySearchSegment(coveringTime: time)
        }
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

    func handleAppResignedActive() {
        guard pausePlayerOnAppHidden,
              let player,
              player.timeControlStatus == .playing else {
            return
        }
        player.pause()
    }

    func maybeSkipSilence(currentTime: Double) {
        guard skipSilences,
              let player,
              player.timeControlStatus == .playing,
              let segments = transcript?.segments,
              !segments.isEmpty else {
            return
        }
        guard let currentSegment = segments.binarySearchSegment(coveringTime: currentTime),
              let nextSegment = segments.firstSegment(startingAfter: currentSegment.end + 0.4) else {
            return
        }
        let gap = nextSegment.start - currentSegment.end
        guard gap >= 0.5 else { return }
        let target = CMTime(seconds: nextSegment.start, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seekTo(seconds: Double) {
        guard let player, seconds.isFinite else { return }
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }
}
