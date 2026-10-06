import Foundation
import Testing
import os
import ParolaCore
@testable import parola

private final class CapturedOutput: Sendable {
    private struct Lines {
        var out: [String] = []
        var err: [String] = []
    }

    private let lines = OSAllocatedUnfairLock(initialState: Lines())

    var sink: RecordSink {
        RecordSink(
            out: { line in self.lines.withLock { $0.out.append(line) } },
            err: { line in self.lines.withLock { $0.err.append(line) } }
        )
    }

    var out: [String] { lines.withLock { $0.out } }
}

@Suite("parola record output")
struct RecordOutputTests {
    @Test("a finished take is written with the Italian orthography fixed")
    func emitAppliesOrthography() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-record-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let record = try Record.parse(["--format", "txt", "--output", path])
        let take = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "Non so perchè."),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "Un pò di più."),
            ],
            language: "it",
            modelName: "openai_whisper-tiny"
        )

        try record.emit(take)

        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(written.contains("Non so perché."))
        #expect(written.contains("Un po' di più."))
        #expect(!written.contains("perchè"))
    }

    private func takeEvents(_ segments: [TranscriptSegment]) -> AsyncStream<StreamingEvent> {
        let (events, continuation) = AsyncStream<StreamingEvent>.makeStream()
        for segment in segments { continuation.yield(.confirmed(segment)) }
        continuation.yield(.finished(Transcript(segments: segments, language: "en", modelName: "openai_whisper-tiny")))
        continuation.finish()
        return events
    }

    @Test("a take an interrupt left without words writes nothing and ends as interrupted")
    func interruptedTakeWithoutWordsWritesNothing() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-record-\(UUID().uuidString).srt").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let record = try Record.parse(["--stream", "--format", "srt", "--output", path])

        let endedByInterrupt = await record.play(takeEvents([]), interrupted: { true }, sink: CapturedOutput().sink)

        #expect(endedByInterrupt)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("a take Ctrl-C stopped after words came, or an empty one nobody interrupted, is written as before", arguments: [true, false])
    func otherTakesAreWritten(interrupted: Bool) async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-record-\(UUID().uuidString).srt").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let record = try Record.parse(["--stream", "--format", "srt", "--output", path])
        let words = interrupted ? [TranscriptSegment(id: 0, start: 0, end: 1, text: "kept words")] : []

        let endedByInterrupt = await record.play(takeEvents(words), interrupted: { interrupted }, sink: CapturedOutput().sink)

        #expect(!endedByInterrupt)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("a streamed txt take prints each confirmed line tidied, and nothing more at the end")
    func streamedLinesAreTidied() throws {
        let record = try Record.parse(["--stream", "--language", "it"])
        let captured = CapturedOutput()
        var lines = LiveLineTidier(language: "it")
        let events: [StreamingEvent] = [
            .partial(text: "Non so perchè"),
            .confirmed(TranscriptSegment(id: 0, start: 0, end: 1, text: "Non so perchè.")),
            .confirmed(TranscriptSegment(id: 1, start: 1, end: 3, text: "Sottotitoli creati dalla comunità Amara.org")),
            .confirmed(TranscriptSegment(id: 2, start: 3, end: 4, text: " Un pò di più.")),
            .finished(Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Non so perchè.")],
                language: "it",
                modelName: "openai_whisper-tiny"
            )),
        ]

        for event in events { record.handle(event, lines: &lines, sink: captured.sink) }

        #expect(captured.out == ["Non so perché.", "Un po' di più."])
    }

    @Test("with no pinned language, the lines are fixed once the take reads as Italian")
    func unpinnedLinesFollowTheText() throws {
        let record = try Record.parse(["--stream"])
        let captured = CapturedOutput()
        var lines = LiveLineTidier(language: nil)

        record.handle(
            .confirmed(TranscriptSegment(
                id: 0, start: 0, end: 4,
                text: "Buongiorno a tutti, oggi parliamo della distinta base e dei componenti ordinati."
            )),
            lines: &lines,
            sink: captured.sink
        )
        record.handle(
            .confirmed(TranscriptSegment(id: 1, start: 4, end: 6, text: "Non so perchè il magazzino è vuoto.")),
            lines: &lines,
            sink: captured.sink
        )

        #expect(captured.out.last == "Non so perché il magazzino è vuoto.")
    }
}
