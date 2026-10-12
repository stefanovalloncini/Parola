import Foundation
import Observation
import Testing
@testable import Parola
import ParolaCore

@Suite("Playback row observation")
@MainActor
struct PlaybackRowObservationTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private func makeController() async -> PlaybackController {
        let controller = PlaybackController()
        controller.load(audioURL: nil, transcript: Fixtures.makeLongTranscript(segments: 40, wordsPerSegment: 10))
        await controller._indexReadyForTest()
        controller._setCurrentTimeForTest(0.1)
        return controller
    }

    private func invalidatedRows(
        _ controller: PlaybackController,
        rows: Int,
        track: (PlaybackController, Int) -> Void,
        change: () -> Void
    ) -> Int {
        let counter = Counter()
        for row in 0..<rows {
            withObservationTracking { track(controller, row) } onChange: { counter.bump() }
        }
        change()
        return counter.count
    }

    @Test("a word change inside the active segment invalidates only that row")
    func wordChangeTouchesOneRow() async {
        let controller = await makeController()
        let rows = invalidatedRows(controller, rows: 40) { controller, row in
            _ = controller.activeWordID(inSegment: row)
        } change: {
            controller._setCurrentTimeForTest(0.5)
        }
        #expect(rows == 1)
    }

    @Test("the old per-row reads invalidate every row on the same word change")
    func previousPatternTouchesEveryRow() async {
        let controller = await makeController()
        let rows = invalidatedRows(controller, rows: 40) { controller, _ in
            _ = controller.currentSegmentID
            _ = controller.currentWordID
        } change: {
            controller._setCurrentTimeForTest(0.5)
        }
        #expect(rows == 40)
    }

    @Test("a segment change reaches every row's active check, once per segment")
    func segmentChangeTouchesEveryActiveCheck() async {
        let controller = await makeController()
        let rows = invalidatedRows(controller, rows: 40) { controller, row in
            _ = controller.activeWordID(inSegment: row)
        } change: {
            controller._setCurrentTimeForTest(4.1)
        }
        #expect(rows == 40)
    }
}
