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

    @Test("the caption the panel rolls is the newest line and the partial, and nothing older")
    func captionText() {
        var s = LiveCaptionsState(confirmedLines: ["older line", "newest line"], partial: "  and the words so far ")
        #expect(s.captionText == "newest line and the words so far")
        s.partial = ""
        #expect(s.captionText == "newest line")
        #expect(LiveCaptionsState().captionText == "")
    }

    @Test("a download fraction clears when the session resets or fails")
    func downloadFractionClears() {
        var s = LiveCaptionsState(isActive: true, isLoading: true, downloadFraction: 0.4)
        s.apply(.failed("no"))
        #expect(s.downloadFraction == nil)
        s.downloadFraction = 0.9
        s.reset()
        #expect(s.downloadFraction == nil)
    }

    @Test("the newest words stay visible when the line before them is confirmed")
    func newestWordsSurviveAConfirm() {
        var s = LiveCaptionsState()
        s.apply(.partial(text: "That is exactly the"))
        s.apply(.confirmed(TranscriptSegment(id: 0, start: 0, end: 4, text: "finish a sentence,")))
        #expect(s.captionText == "finish a sentence, That is exactly the")

        s.apply(.partial(text: "all from me."))
        s.apply(.confirmed(TranscriptSegment(id: 1, start: 4, end: 6, text: "all from me.")))
        #expect(s.partial.isEmpty, "a partial that is the confirmed line itself is done")

        s.apply(.partial(text: "so let me hand"))
        s.apply(.confirmed(TranscriptSegment(id: 2, start: 6, end: 7, text: "so let")))
        #expect(s.partial == "me hand", "what follows the confirmed words stays")
    }

    @Test("a confirm takes the confirmed words off the partial, word by word, and keeps what was said after", arguments: [
        ("I", "It's fine", "It's fine"),
        ("That is all.", "that is all", ""),
        ("all from me.", "all from me", ""),
        ("so let me hand,", "So let me hand", ""),
        ("No, no.", "No", ""),
        ("so let", "so let me hand", "me hand"),
        ("finish a sentence,", "That is exactly the", "That is exactly the"),
        ("hello world", "hel", ""),
        ("that is all.", "that is all so", "so"),
        ("I went home.", "I was tired", "I was tired"),
        ("So we ship it.", "So the next thing", "So the next thing"),
        ("That is all.", "That was", "That was"),
    ])
    func confirmStripsWords(confirmed: String, partial: String, left: String) {
        var s = LiveCaptionsState(partial: partial)
        s.apply(.confirmed(TranscriptSegment(id: 0, start: 0, end: 1, text: confirmed)))
        #expect(s.partial == left)
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

    @Test("the history keeps every confirmed line while the display keeps the last few")
    func historyOutlivesTheDisplay() {
        var s = LiveCaptionsState()
        for index in 0..<10 {
            s.apply(.confirmed(TranscriptSegment(id: index, start: Double(index), end: Double(index) + 1, text: "line \(index)")))
        }
        s.apply(.partial(text: "still talking"))

        #expect(s.history.count == 10)
        #expect(s.confirmedLines == ["line 6", "line 7", "line 8", "line 9"])
        #expect(s.historyText == (0..<10).map { "line \($0)" }.joined(separator: "\n") + "\nstill talking")
    }

    @Test("a restarted run carries the earlier run's history and display")
    func continuingKeepsTheEarlierRun() {
        var earlier = LiveCaptionsState(maxLines: 2)
        for text in ["one", "two", "three"] {
            earlier.apply(.confirmed(TranscriptSegment(id: 0, start: 0, end: 1, text: text)))
        }
        var restarted = LiveCaptionsState(maxLines: 2)
        restarted.apply(.confirmed(TranscriptSegment(id: 0, start: 0, end: 1, text: "four")))

        restarted.continuing(after: earlier)

        #expect(restarted.history == ["one", "two", "three", "four"])
        #expect(restarted.confirmedLines == ["three", "four"])
    }

    @Test("failed event records error and deactivates")
    func failedEvent() {
        var s = LiveCaptionsState(isActive: true)
        s.apply(.failed("mic disconnected"))
        #expect(s.error == "mic disconnected")
        #expect(s.isActive == false)
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
        #expect(s.history.isEmpty)
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
