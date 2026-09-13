import Foundation
import Testing
import ParolaCore
@testable import Parola

@Suite("Entry row")
struct EntryRowTests {
    @Test("an excerpt stops on the last whole word that fits and says it was cut")
    func excerptCutsOnAWordBoundary() {
        let text = "Il primo paragrafo della trascrizione continua ben oltre il limite richiesto."
        #expect(LibrarySearchIndex.excerpt(from: text, maxLength: 30) == "Il primo paragrafo della…")
    }

    @Test("an excerpt that fits is quoted whole, without an ellipsis")
    func shortTextIsQuotedWhole() {
        #expect(LibrarySearchIndex.excerpt(from: "Due parole.", maxLength: 240) == "Due parole.")
    }

    @Test("line breaks and runs of spaces collapse to one space")
    func whitespaceCollapses() {
        let text = "  Prima riga.\n\nSeconda   riga.\t Terza.  "
        #expect(LibrarySearchIndex.excerpt(from: text, maxLength: 240) == "Prima riga. Seconda riga. Terza.")
    }

    @Test("an entry with nothing indexed has no excerpt at all")
    func emptyTextHasNoExcerpt() {
        #expect(LibrarySearchIndex.excerpt(from: "", maxLength: 240) == nil)
        #expect(LibrarySearchIndex.excerpt(from: "   \n  ", maxLength: 240) == nil)
        #expect(LibrarySearchIndex.excerpt(from: "parola", maxLength: 0) == nil)
    }

    /// A word longer than the whole allowance has no boundary to cut on, and still must not run past it.
    @Test("a single long word is cut where the allowance ends")
    func oneLongWordIsCutHard() {
        let excerpt = LibrarySearchIndex.excerpt(from: String(repeating: "a", count: 40), maxLength: 10)
        #expect(excerpt == String(repeating: "a", count: 10) + "…")
    }

    private func entry(
        _ name: String,
        category: EntryCategory = .transcription,
        model: String = "stub"
    ) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            originalAudioName: name,
            title: name,
            modelName: model,
            language: "en",
            category: category
        )
        return LibraryEntry(
            id: "e",
            bundleURL: URL(fileURLWithPath: "/tmp/EntryRowTests/e.parola"),
            manifest: manifest
        )
    }

    @Test("the badge says what the entry was made from, not just that it is a transcription")
    func sourceKindFollowsTheFile() {
        #expect(EntrySourceKind(entry: entry("take.wav")) == .audio)
        #expect(EntrySourceKind(entry: entry("talk.mp4")) == .video)
        #expect(EntrySourceKind(entry: entry("talk.mkv")) == .video)
        #expect(EntrySourceKind(entry: entry("notes")) == .audio)
    }

    @Test("a video's own captions read as a link, and a category wins over the file")
    func sourceKindFollowsTheCategory() {
        #expect(EntrySourceKind(entry: entry("talk.mp4", model: "youtube-subs")) == .web)
        #expect(EntrySourceKind(entry: entry("talk.mp4", model: "youtube-auto-subs")) == .web)
        #expect(EntrySourceKind(entry: entry("standup.mp4", category: .meeting)) == .meeting)
        #expect(EntrySourceKind(entry: entry("memo.wav", category: .dictation)) == .dictation)
    }

    @Test("every source kind has a glyph of its own")
    func everyKindHasItsOwnGlyph() {
        let kinds: [EntrySourceKind] = [.meeting, .dictation, .audio, .video, .web]
        #expect(Set(kinds.map(\.symbol)).count == kinds.count)
    }
}

@Suite("Job row")
struct JobRowTests {
    private func job(
        _ status: BatchJob.Status,
        progress: Double = 0,
        error: String? = nil,
        segments: Int = 0
    ) -> BatchJob {
        BatchJob(
            url: URL(fileURLWithPath: "/tmp/JobRowTests/take.wav"),
            status: status,
            transcript: segments > 0
                ? Transcript(
                    segments: (0..<segments).map {
                        TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: "riga")
                    },
                    language: "it",
                    modelName: "stub"
                )
                : nil,
            error: error,
            progress: progress
        )
    }

    @Test("a job says where it is, in words")
    func statusReadsInWords() {
        #expect(BatchJobStatus.text(for: job(.pending)) == "Queued")
        #expect(BatchJobStatus.text(for: job(.transcribing, progress: 0.32)).contains("32"))
        #expect(BatchJobStatus.text(for: job(.cancelled, progress: 0.4)) == "Cancelled")
        #expect(BatchJobStatus.text(for: job(.failed, error: "no audio track")) == "Failed: no audio track")
        #expect(BatchJobStatus.text(for: job(.failed)) == "Failed")
        #expect(BatchJobStatus.text(for: job(.done, segments: 12)) == "Completed · 12 segments")
    }

    /// Rounding a fraction under a percent prints "0%", which reads as stuck rather than as starting.
    @Test("a job that has just started says so instead of showing a zero")
    func earlyProgressStaysWordy() {
        #expect(BatchJobStatus.text(for: job(.transcribing, progress: 0.004)) == "Transcribing…")
        #expect(BatchJobStatus.text(for: job(.transcribing)) == "Transcribing…")
    }

    @Test("only a job that is still going draws a bar")
    func onlyRunningJobsDrawABar() {
        #expect(!BatchJobStatus.showsProgress(.pending))
        #expect(BatchJobStatus.showsProgress(.transcribing))
        #expect(!BatchJobStatus.showsProgress(.done))
        #expect(!BatchJobStatus.showsProgress(.failed))
        #expect(!BatchJobStatus.showsProgress(.cancelled))
    }

    /// The Queue's ✕ cancels the run; the Batch page's ✕ must stay the per-file control it was.
    @Test("each page's cancel keeps its own meaning and its own ax id")
    func cancelActionsDifferPerPage() {
        var cancelledRun = 0
        let queue = JobCancelAction.wholeBatch { cancelledRun += 1 }
        #expect(queue.axID == "Row.Button.CancelBatch")
        queue.run()
        #expect(cancelledRun == 1)

        var cancelledJob = 0
        let running = JobCancelAction.oneJob(status: .transcribing) { cancelledJob += 1 }
        let waiting = JobCancelAction.oneJob(status: .pending) { cancelledJob += 1 }
        #expect(running.axID == "Row.Button.Cancel")
        #expect(waiting.axID == "Row.Button.Cancel")
        #expect(running.help != waiting.help)
        running.run()
        waiting.run()
        #expect(cancelledJob == 2)
    }

    @Test("a running job has no glyph, since its bar is the indicator")
    func statusGlyphsMatchTheState() {
        #expect(BatchJobStatus.symbol(for: .transcribing) == nil)
        #expect(BatchJobStatus.symbol(for: .done) == "checkmark.circle.fill")
        #expect(BatchJobStatus.symbol(for: .failed) == "exclamationmark.triangle.fill")
    }
}
