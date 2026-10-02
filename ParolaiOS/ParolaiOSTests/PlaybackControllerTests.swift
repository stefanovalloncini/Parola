import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("PlaybackController highlight")
@MainActor
struct PlaybackControllerTests {
    private var sampleAudioURL: URL {
        Bundle(for: BundleAnchor.self).url(forResource: "sample", withExtension: "wav")!
    }

    @Test("currentSegmentID follows currentTime")
    func segmentFollowsTime() {
        let controller = PlaybackController()
        controller.load(audioURL: sampleAudioURL, transcript: Fixtures.makeTranscript())
        controller._setCurrentTimeForTest(0.2)
        #expect(controller.currentSegmentID == 0)
        controller._setCurrentTimeForTest(1.2)
        #expect(controller.currentSegmentID == 1)
    }

    @Test("currentWordID follows currentTime")
    func wordFollowsTime() {
        let controller = PlaybackController()
        controller.load(audioURL: sampleAudioURL, transcript: Fixtures.makeTranscript())
        controller._setCurrentTimeForTest(0.6)
        #expect(controller.currentWordID == "0_1")
    }

    @Test("load twice resets state")
    func loadTwiceResets() {
        let controller = PlaybackController()
        controller.load(audioURL: sampleAudioURL, transcript: Fixtures.makeTranscript())
        controller._setCurrentTimeForTest(1.2)
        #expect(controller.currentSegmentID == 1)
        controller.load(audioURL: sampleAudioURL, transcript: Fixtures.makeTranscript())
        #expect(controller.currentSegmentID == nil)
        #expect(controller.currentTime == 0)
    }

    @Test("currentSegmentID is nil before load")
    func nilBeforeLoad() {
        let controller = PlaybackController()
        #expect(controller.currentSegmentID == nil)
        #expect(controller.currentWordID == nil)
    }

    @Test("hasAudio reflects whether an audio URL was loaded")
    func hasAudioReflectsLoad() {
        let controller = PlaybackController()
        #expect(controller.hasAudio == false)
        controller.load(audioURL: nil, transcript: Fixtures.makeTranscript())
        #expect(controller.hasAudio == false)
        controller.load(audioURL: sampleAudioURL, transcript: Fixtures.makeTranscript())
        #expect(controller.hasAudio)
    }

    @Test("play sets isPlaying and pause clears it")
    func playPauseTogglesIsPlaying() {
        let controller = PlaybackController()
        controller.load(audioURL: sampleAudioURL, transcript: Fixtures.makeTranscript())
        #expect(controller.isPlaying == false)
        controller.play()
        #expect(controller.isPlaying)
        controller.pause()
        #expect(controller.isPlaying == false)
    }

    @Test("toggle alternates the play state")
    func toggleAlternates() {
        let controller = PlaybackController()
        controller.load(audioURL: sampleAudioURL, transcript: Fixtures.makeTranscript())
        controller.toggle()
        #expect(controller.isPlaying)
        controller.toggle()
        #expect(controller.isPlaying == false)
    }

    @Test("play and pause are ignored when there is no audio")
    func transportNoOpsWithoutAudio() {
        let controller = PlaybackController()
        controller.load(audioURL: nil, transcript: Fixtures.makeTranscript())
        controller.play()
        #expect(controller.isPlaying == false)
        controller.toggle()
        #expect(controller.isPlaying == false)
    }

    @Test("seek moves currentTime and updates the current segment")
    func seekUpdatesTimeAndSegment() {
        let controller = PlaybackController()
        controller.load(audioURL: sampleAudioURL, transcript: Fixtures.makeTranscript())
        controller.seek(to: 1.2)
        #expect(controller.currentTime == 1.2)
        #expect(controller.currentSegmentID == 1)
    }

    @Test("a periodic tick during a pending seek doesn't move the shown time")
    func pendingSeekIgnoresObserverTicks() {
        let controller = PlaybackController()
        controller.load(audioURL: sampleAudioURL, transcript: Fixtures.makeTranscript())
        controller.seek(to: 1.2)
        controller._simulateObserverTickForTest(0.5)
        #expect(controller.currentTime == 1.2)
        #expect(controller.currentSegmentID == 1)
    }

    @Test("an older seek's completion doesn't release a newer seek's hold")
    func olderSeekCompletionDoesNotReleaseNewerSeek() {
        let controller = PlaybackController()
        controller.load(audioURL: sampleAudioURL, transcript: Fixtures.makeTranscript())

        controller.seek(to: 0.2)
        let olderGeneration = controller._latestSeekGenerationForTest

        controller.seek(to: 1.2)
        controller._completeSeekForTest(generation: olderGeneration, time: 0.2)

        #expect(controller.currentTime == 1.2)
        #expect(controller.currentSegmentID == 1)
    }

    @Test("playing at the end rewinds to zero before resuming")
    func playRewindsAtEnd() async throws {
        let controller = PlaybackController()
        controller.load(audioURL: sampleAudioURL, transcript: Fixtures.makeTranscript())
        try await pollUntil { controller.duration > 0 }
        controller._setCurrentTimeForTest(controller.duration)
        controller.play()
        #expect(controller.currentTime == 0)
        #expect(controller.currentSegmentID == 0)
        #expect(controller.isPlaying)
    }

    @Test("loading again tears down the previous player and resets state")
    func reloadTearsDownAndResets() {
        let controller = PlaybackController()
        controller.load(audioURL: sampleAudioURL, transcript: Fixtures.makeTranscript())
        controller.play()
        controller._setCurrentTimeForTest(1.2)
        #expect(controller.isPlaying)
        controller.load(audioURL: nil, transcript: Fixtures.makeTranscript())
        #expect(controller.isPlaying == false)
        #expect(controller.currentTime == 0)
        #expect(controller.duration == 0)
        #expect(controller.currentSegmentID == nil)
        #expect(controller.currentWordID == nil)
        #expect(controller.hasAudio == false)
    }

    @Test("a released controller cancels its duration task and removes its time observer")
    func releasedControllerTearsDown() async throws {
        let before = PlaybackController.liveTimeObserverCount
        weak var observed: PlaybackController?
        do {
            let controller = PlaybackController()
            controller.load(audioURL: sampleAudioURL, transcript: Fixtures.makeTranscript())
            observed = controller
            #expect(PlaybackController.liveTimeObserverCount == before + 1)
        }
        try await pollUntil { observed == nil }
        let deallocated = observed == nil
        #expect(deallocated)
        try await pollUntil { PlaybackController.liveTimeObserverCount == before }
        let afterCount = PlaybackController.liveTimeObserverCount
        #expect(afterCount == before)
    }
}

private final class BundleAnchor {}
