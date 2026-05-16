import Foundation
import Testing
@testable import ParolaCore

@Suite("Live captions state")
struct LiveCaptionsStateTests {
    @Test("empty state has empty displayed text")
    func emptyState() {
        let s = LiveCaptionsState()
        #expect(s.displayedText == "")
    }

    @Test("partial event appears in displayed text")
    func partial() {
        var s = LiveCaptionsState()
        s.apply(.partial(text: "hel"))
        #expect(s.displayedText == "hel")
    }

    @Test("confirmed event adds a line and clears partial")
    func confirmed() {
        var s = LiveCaptionsState()
        s.apply(.partial(text: "hel"))
        s.apply(.confirmed(TranscriptSegment(id: 0, start: 0, end: 1, text: "hello world")))
        #expect(s.confirmedLines == ["hello world"])
        #expect(s.partial == "")
        #expect(s.displayedText == "hello world")
    }

    @Test("rolling window keeps only the most recent lines")
    func rollingWindow() {
        var s = LiveCaptionsState(maxLines: 2)
        s.apply(.confirmed(TranscriptSegment(id: 0, start: 0, end: 1, text: "one")))
        s.apply(.confirmed(TranscriptSegment(id: 1, start: 1, end: 2, text: "two")))
        s.apply(.confirmed(TranscriptSegment(id: 2, start: 2, end: 3, text: "three")))
        #expect(s.confirmedLines == ["two", "three"])
    }

    @Test("failed event records error and deactivates")
    func failedEvent() {
        var s = LiveCaptionsState(isActive: true)
        s.apply(.failed("mic disconnected"))
        #expect(s.error == "mic disconnected")
        #expect(!s.isActive)
    }

    @Test("finished event clears partial")
    func finishedEvent() {
        var s = LiveCaptionsState()
        s.apply(.partial(text: "incomplete"))
        s.apply(.finished(Transcript(segments: [], language: "en", modelName: "tiny")))
        #expect(s.partial == "")
    }

    @Test("reset wipes lines, partial, and error")
    func reset() {
        var s = LiveCaptionsState()
        s.apply(.confirmed(TranscriptSegment(id: 0, start: 0, end: 1, text: "line")))
        s.apply(.partial(text: "part"))
        s.error = "bad"
        s.reset()
        #expect(s.confirmedLines.isEmpty)
        #expect(s.partial.isEmpty)
        #expect(s.error == nil)
    }

    @Test("empty confirmed segments are skipped")
    func emptySegmentsSkipped() {
        var s = LiveCaptionsState()
        s.apply(.confirmed(TranscriptSegment(id: 0, start: 0, end: 1, text: "   ")))
        #expect(s.confirmedLines.isEmpty)
    }
}
