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
    func seekUpdatesTimeAndSegment() async throws {
        let controller = PlaybackController()
        controller.load(audioURL: sampleAudioURL, transcript: Fixtures.makeTranscript())
        controller.seek(to: 1.2)
        try await pollUntil { controller.currentTime == 1.2 }
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

    private func pollUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}

private final class BundleAnchor {}
