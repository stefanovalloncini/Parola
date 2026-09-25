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
        pendingRevealSegmentID = nil
        currentWordID = nil
        mediaDurationSeconds = nil
        transcriptMatchesLoadedMedia = false
    }

    /// Declares that the loaded transcript describes the media the player holds, so that media's length wins.
    func adoptLoadedMediaDuration() {
        transcriptMatchesLoadedMedia = true
        applyLoadedMediaDuration()
    }

    func applyLoadedMediaDuration() {
        guard transcriptMatchesLoadedMedia,
              let duration = mediaDurationSeconds, duration > 0,
              var patched = transcript,
              abs((patched.durationSeconds ?? 0) - duration) > 0.05 else { return }
        patched.durationSeconds = duration
        transcript = patched
        // The assignment clears the flag through didSet, and the patched transcript still describes this media.
        transcriptMatchesLoadedMedia = true
        persistCorrectedDuration(duration)
    }

    // The manifest alone: rewriting transcript.json would move updatedAt for an edit the user never made.
    private func persistCorrectedDuration(_ seconds: Double) {
        guard let id = selectedEntryID else { return }
        let bundleURL = library.libraryURL.appendingPathComponent("\(id).parola", isDirectory: true)
        Task {
            let written: Void? = try? await Self.offMainIO {
                try ParolaDocument.updateManifest(at: bundleURL) { $0.durationSeconds = seconds }
            }
            guard written != nil else { return }
            patchLibraryEntry(id: id) { $0.durationSeconds = seconds }
        }
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
                guard let self, self.isPlaying != playing else { return }
                self.isPlaying = playing
            }
        }
        Task { [weak self] in
            // An asset load on an unreachable file parks a work-queue thread that no cancel
            // reaches, so the wait is bounded and the thread abandoned on expiry.
            let loaded = await AsyncTimeout.run(FileReadDeadline.header) {
                await Self.loadAssetInfo(url: url)
            }
            guard let self, let loaded, self.playerInstallToken == token else { return }
            self.hasVideo = loaded.hasVideo
            if let assetDuration = loaded.durationSeconds, assetDuration.isFinite, assetDuration > 0 {
                self.mediaDurationSeconds = assetDuration
                self.applyLoadedMediaDuration()
            }
        }
    }

    private struct LoadedAssetInfo: Sendable {
        var hasVideo: Bool
        var durationSeconds: Double?
    }

    private nonisolated static func loadAssetInfo(url: URL) async -> LoadedAssetInfo {
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
        return LoadedAssetInfo(hasVideo: !tracks.isEmpty, durationSeconds: duration)
    }

    /// Re-points playback at a finished run's own audio: an entry opened mid-run leaves the player on the entry's file.
    func restorePlaybackSource(_ url: URL) {
        guard sourceFileURL != url else { return }
        sourceFileURL = url
        installPlayer(for: url)
    }

    func updateCurrentSegment(time: Double) {
        guard let segments = transcript?.segments else { return }
        // A reveal owns the selection until playback starts: the player's first tick lands after it,
        // covers t = 0, and would drag a transcript opened at a search hit back to the top.
        if pendingRevealSegmentID != nil {
            guard player?.timeControlStatus == .playing else { return }
            pendingRevealSegmentID = nil
        }
        let matchIndex = cachedOrSearchedIndex(in: segments, coveringTime: time)
        currentSegmentIndex = matchIndex
        let match = matchIndex.map { segments[$0] }
        if currentSegmentID != match?.id {
            currentSegmentID = match?.id
        }
        let newWordID = match?.word(at: time)?.id
        if currentWordID != newWordID {
            currentWordID = newWordID
        }
    }

    private func cachedOrSearchedIndex(in segments: [TranscriptSegment], coveringTime time: Double) -> Int? {
        if let idx = currentSegmentIndex,
           segments.indices.contains(idx),
           segments[idx].id == currentSegmentID,
           time >= segments[idx].start, time <= segments[idx].end {
            return idx
        }
        // Externally-set currentSegmentID (find navigation, deep links) has no cached index yet;
        // honor its stickiness once, then the index fast path takes over.
        if let cached = currentSegmentID,
           let idx = segments.firstIndex(where: { $0.id == cached }),
           time >= segments[idx].start, time <= segments[idx].end {
            return idx
        }
        return segments.binarySearchSegmentIndex(coveringTime: time)
    }

    /// Every seek the user asks for lands here: it hands the selection back from a reveal first, so
    /// the highlight follows a scrub made without pressing play. `precise` is false for the scrubber,
    /// which reads better with the tolerance AVPlayer picks.
    func seekPlayer(to seconds: Double, precise: Bool = true) {
        guard seconds.isFinite else { return }
        let target = max(0, seconds)
        pendingRevealSegmentID = nil
        currentTimeSeconds = target
        updateCurrentSegment(time: target)
        guard let player else { return }
        let time = CMTime(seconds: target, preferredTimescale: 600)
        if precise {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            player.seek(to: time)
        }
    }

    func seek(to segment: TranscriptSegment) {
        guard let player else { return }
        seekPlayer(to: segment.start)
        player.play()
    }

    func seekTo(chapter: Chapter) {
        guard let player else { return }
        seekPlayer(to: chapter.start)
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
              let target = Self.silenceSkipTarget(at: currentTime, in: segments) else {
            return
        }
        seekPlayer(to: target)
    }

    /// Just before the next segment when the playhead sits in a gap of at least `minimumGap`, the lead-in included; nil inside speech or after the last segment.
    static func silenceSkipTarget(
        at time: Double,
        in segments: [TranscriptSegment],
        minimumGap: Double = 0.5,
        lead: Double = 0.1
    ) -> Double? {
        var spokenUntil: Double?
        for segment in segments {
            guard segment.start <= time else {
                if let spokenUntil, spokenUntil >= time { return nil }
                let silenceStart = spokenUntil ?? 0
                guard segment.start - silenceStart >= minimumGap else { return nil }
                let target = max(silenceStart, segment.start - lead)
                return target - time > 0.05 ? target : nil
            }
            spokenUntil = max(spokenUntil ?? segment.end, segment.end)
        }
        return nil
    }

    func seekTo(seconds: Double) {
        guard let player, seconds.isFinite else { return }
        seekPlayer(to: seconds)
        player.play()
    }

    static func skipTarget(current: Double, by delta: Double) -> Double {
        max(0, current + delta)
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    func skip(by seconds: Double) {
        guard let player else { return }
        let current = CMTimeGetSeconds(player.currentTime())
        guard current.isFinite else { return }
        seekPlayer(to: Self.skipTarget(current: current, by: seconds))
    }

    func seekToSegment(id: TranscriptSegment.ID) {
        guard player != nil, let seg = transcript?.segments.first(where: { $0.id == id }) else { return }
        seek(to: seg)
    }
}
