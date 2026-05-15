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
}

private final class BundleAnchor {}
