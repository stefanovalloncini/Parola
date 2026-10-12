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
    @ObservationIgnored private var durationTask: Task<Void, Never>?
    @ObservationIgnored private var seekGeneration = 0
    @ObservationIgnored private var pendingSeek: Int?
    @ObservationIgnored var seekHoldLimit: Duration = .milliseconds(750)

    var hasAudio: Bool { player != nil }

    func isActive(segment id: TranscriptSegment.ID) -> Bool { currentSegmentID == id }

    /// Reads the word only for the active segment, so a word change invalidates no other row.
    func activeWordID(inSegment id: TranscriptSegment.ID) -> WordTiming.ID? {
        currentSegmentID == id ? currentWordID : nil
    }

    isolated deinit {
        tearDown()
    }

    func load(audioURL: URL?, transcript: Transcript) {
        tearDown()
        index = TranscriptIndex(transcript: transcript)
        guard let audioURL else { return }

        let item = AVPlayerItem(url: audioURL)
        let player = AVPlayer(playerItem: item)
        self.player = player

        durationTask?.cancel()
        durationTask = Task { [weak self] in
            let seconds = try? await item.asset.load(.duration).seconds
            guard !Task.isCancelled else { return }
            self?.duration = seconds ?? 0
        }

        let interval = CMTime(seconds: 0.1, preferredTimescale: 1000)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.observerTick(time.seconds.isFinite ? time.seconds : 0)
            }
        }
        #if DEBUG
        Self.liveTimeObserverCount += 1
        #endif
    }

    func play() {
        guard let player else { return }
        configurePlaybackSession()
        if duration > 0, currentTime >= duration - 0.05 {
            seekGeneration += 1
            pendingSeek = nil
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            tick(to: 0)
        }
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
        seekGeneration += 1
        let generation = seekGeneration
        pendingSeek = generation
        tick(to: time)
        let holdLimit = seekHoldLimit
        Task { [weak self] in
            _ = await player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            self?.seekCompleted(generation: generation, time: time)
        }
        Task { [weak self] in
            try? await Task.sleep(for: holdLimit)
            self?.releaseHold(generation: generation)
        }
    }

    private func configurePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback)
        try? session.setActive(true)
    }

    private func observerTick(_ time: TimeInterval) {
        guard pendingSeek == nil else { return }
        tick(to: time)
    }

    private func seekCompleted(generation: Int, time: TimeInterval) {
        guard pendingSeek == generation else { return }
        pendingSeek = nil
        tick(to: time)
    }

    private func releaseHold(generation: Int) {
        guard pendingSeek == generation else { return }
        pendingSeek = nil
    }

    private func tick(to time: TimeInterval) {
        currentTime = time
        let segID = index?.segmentID(at: time)
        if segID != currentSegmentID { currentSegmentID = segID }
        let wordID = index?.word(at: time)?.id
        if wordID != currentWordID { currentWordID = wordID }
    }

    #if DEBUG
    static var liveTimeObserverCount = 0

    func _setCurrentTimeForTest(_ value: TimeInterval) {
        tick(to: value)
    }

    var _latestSeekGenerationForTest: Int { seekGeneration }

    func _completeSeekForTest(generation: Int, time: TimeInterval) {
        seekCompleted(generation: generation, time: time)
    }

    func _simulateObserverTickForTest(_ value: TimeInterval) {
        observerTick(value)
    }

    func _releaseHoldForTest(generation: Int) {
        releaseHold(generation: generation)
    }
    #endif

    private func tearDown() {
        durationTask?.cancel()
        durationTask = nil
        pendingSeek = nil
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
            #if DEBUG
            Self.liveTimeObserverCount -= 1
            #endif
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
