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

    @Test("before the index lands the segment still follows time, and the word arrives with the index")
    func segmentLevelUntilIndexLands() async {
        let controller = PlaybackController()
        controller.load(audioURL: sampleAudioURL, transcript: Fixtures.makeTranscript())
        controller._setCurrentTimeForTest(0.6)
        #expect(controller.index == nil)
        #expect(controller.currentSegmentID == 0)
        #expect(controller.currentWordID == nil)
        await controller._indexReadyForTest()
        #expect(controller.index != nil)
        #expect(controller.currentWordID == "0_1")
    }

    @Test("an entry without audio shows no highlight when its index lands")
    func noAudioNoHighlight() async {
        let controller = PlaybackController()
        controller.load(audioURL: nil, transcript: Fixtures.makeTranscript())
        await controller._indexReadyForTest()
        #expect(controller.index != nil)
        #expect(controller.currentSegmentID == nil)
        #expect(controller.currentWordID == nil)
    }

    @Test("a stale index from the previous entry never lands")
    func staleIndexDropped() async {
        let controller = PlaybackController()
        controller.load(audioURL: nil, transcript: Fixtures.makeLongTranscript(segments: 2000))
        let first = controller._indexTaskForTest
        controller.load(audioURL: nil, transcript: Fixtures.makeTranscript())
        await controller._indexReadyForTest()
        await first?.value
        #expect(controller.index?.segments.count == 2)
    }

    @Test("leaving the entry cancels the pending index")
    func leavingCancelsIndex() async {
        let controller = PlaybackController()
        controller.load(audioURL: nil, transcript: Fixtures.makeLongTranscript(segments: 2000))
        let task = controller._indexTaskForTest
        controller.cancelIndexing()
        await task?.value
        #expect(controller.index == nil)
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
    func wordFollowsTime() async {
        let controller = PlaybackController()
        controller.load(audioURL: sampleAudioURL, transcript: Fixtures.makeTranscript())
        await controller._indexReadyForTest()
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

    @Test("a stalled seek releases its hold after the bound")
    func stalledSeekReleasesHoldAfterBound() {
        let controller = PlaybackController()
        controller.load(audioURL: sampleAudioURL, transcript: Fixtures.makeTranscript())
        controller.seek(to: 1.2)
        let generation = controller._latestSeekGenerationForTest

        controller._simulateObserverTickForTest(0.5)
        #expect(controller.currentTime == 1.2)
        #expect(controller.currentSegmentID == 1)

        controller._releaseHoldForTest(generation: generation)
        controller._simulateObserverTickForTest(0.5)
        #expect(controller.currentTime == 0.5)
        #expect(controller.currentSegmentID == 0)
    }

    @Test("a late completion after the hold already released doesn't regress the highlight")
    func lateCompletionAfterReleaseDoesNotRegress() {
        let controller = PlaybackController()
        controller.load(audioURL: sampleAudioURL, transcript: Fixtures.makeTranscript())
        controller.seek(to: 1.2)
        let generation = controller._latestSeekGenerationForTest

        controller._releaseHoldForTest(generation: generation)
        controller._simulateObserverTickForTest(0.5)
        #expect(controller.currentTime == 0.5)
        #expect(controller.currentSegmentID == 0)

        controller._completeSeekForTest(generation: generation, time: 1.2)
        #expect(controller.currentTime == 0.5)
        #expect(controller.currentSegmentID == 0)
    }

    @Test("play's rewind clears a pending seek so a stale completion can't snap back")
    func rewindClearsPendingSeekBeforeStaleCompletion() async throws {
        let controller = PlaybackController()
        controller.load(audioURL: sampleAudioURL, transcript: Fixtures.makeTranscript())
        try await pollUntil { controller.duration > 0 }

        controller.seek(to: controller.duration)
        let staleGeneration = controller._latestSeekGenerationForTest
        let staleTarget = controller.duration

        controller.play()
        #expect(controller.currentTime == 0)
        #expect(controller.currentSegmentID == 0)
        #expect(controller.isPlaying)

        controller._completeSeekForTest(generation: staleGeneration, time: staleTarget)
        #expect(controller.currentTime == 0)
        #expect(controller.currentSegmentID == 0)
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
