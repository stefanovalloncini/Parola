import AppKit
import Foundation
import SwiftUI
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

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
        model: String = "stub",
        source: EntrySource? = nil
    ) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            originalAudioName: name,
            title: name,
            modelName: model,
            language: "en",
            category: category,
            source: source
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

    @Test("a link transcribed with a local model still reads as a link")
    func sourceKindFollowsTheManifest() {
        #expect(EntrySourceKind(entry: entry("audio.m4a", source: .web)) == .web)
        #expect(EntrySourceKind(entry: entry("video.mp4", source: .web)) == .web)
    }

    @Test("a take reads as audio whatever its working file is called")
    func sourceKindOfATake() {
        #expect(EntrySourceKind(entry: entry("take.mp4", source: .microphone)) == .audio)
        #expect(EntrySourceKind(entry: entry("take.mp4", source: .systemAudio)) == .audio)
    }

    @Test("every source kind has a glyph of its own")
    func everyKindHasItsOwnGlyph() {
        let kinds: [EntrySourceKind] = [.meeting, .dictation, .audio, .video, .web]
        #expect(Set(kinds.map(\.symbol)).count == kinds.count)
    }
}

@MainActor
@Suite("Entry row layout")
struct EntryRowLayoutTests {
    private static let width: CGFloat = 520

    private func entry(
        _ title: String,
        model: String = "stub",
        language: String = "en",
        labels: [String] = [],
        notes: Int = 0,
        pinned: Bool = false,
        seconds: Double? = nil
    ) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            originalAudioName: "\(title).m4a",
            title: title,
            modelName: model,
            language: language,
            labels: labels,
            segmentNotes: Dictionary(uniqueKeysWithValues: (0..<notes).map { ("\($0)", "note") }),
            pinned: pinned,
            durationSeconds: seconds
        )
        return LibraryEntry(id: "e", bundleURL: URL(fileURLWithPath: "/tmp/EntryRowLayoutTests/e.parola"), manifest: manifest)
    }

    private func makeModel() async -> AppModel {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("entry-row-layout"))
        await model.libraryRefreshTask?.value
        return model
    }

    private func height(_ row: some View, in model: AppModel, typeSize: DynamicTypeSize = .large) -> CGFloat {
        let host = NSHostingView(
            rootView: row
                .environment(model)
                .environment(\.dynamicTypeSize, typeSize)
                .frame(width: Self.width)
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private var plain: LibraryRowDisplay {
        LibraryRowDisplay(entry: entry("Standup"))
    }

    private var busy: LibraryRowDisplay {
        LibraryRowDisplay(
            entry: entry(
                String(repeating: "Weekly product sync ", count: 6),
                language: "it",
                labels: ["draft", "shared", "q4"],
                notes: 2,
                pinned: true,
                seconds: 4320
            ),
            excerpt: String(repeating: "parola ", count: 80),
            usualLanguage: "EN"
        )
    }

    private var snippet: EntryRowDetail {
        .snippet(AttributedString(String(repeating: "parola ", count: 80)), timecode: "1:02:34", reservesTimecode: true)
    }

    @Test("every row is 50 pt tall, whatever it carries")
    func everyRowIsOneHeight() async {
        let model = await makeModel()

        #expect(height(EntryRow(display: plain), in: model) == EntryRowMetrics.height)
        #expect(height(EntryRow(display: busy, detail: .excerpt(busy.excerpt)), in: model) == EntryRowMetrics.height)
        #expect(height(EntryRow(display: busy, detail: snippet) { Text(verbatim: "12 matches") }, in: model)
            == EntryRowMetrics.height)
    }

    /// The height is declared so the table never measures a row; at an accessibility size the row measures itself.
    @Test("what the busiest row holds fits the height every row declares")
    func theBusiestRowFits() async {
        let model = await makeModel()

        #expect(height(EntryRow(display: busy, detail: .excerpt(busy.excerpt)), in: model, typeSize: .accessibility1)
            <= EntryRowMetrics.height)
        #expect(height(EntryRow(display: busy, detail: snippet), in: model, typeSize: .accessibility1)
            <= EntryRowMetrics.height)
    }

    @Test("a row never names the model it was transcribed with")
    func rowsLeaveTheModelOut() {
        let display = LibraryRowDisplay(entry: entry("Weekly sync", model: "openai_whisper-large-v3-v20240930_turbo"))
        let said = Mirror(reflecting: display).children.compactMap { $0.value as? String }

        #expect(said.contains("Weekly sync"))
        #expect(!said.contains { $0.localizedCaseInsensitiveContains("whisper") })
    }

    /// The slot is fixed so every row's time lines up; too narrow a one would cut the longest length short.
    @Test("the length slot fits the longest length a row shows")
    func durationSlotFitsTheLongestLength() throws {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let longest = try #require(LibraryRowFormat.duration(23 * 3600 + 59 * 60))
        #expect((longest as NSString).size(withAttributes: [.font: font]).width <= EntryRowMetrics.durationWidth)
    }
}

@MainActor
@Suite("Job row")
struct JobRowTests {
    private func text(
        _ status: BatchJob.Status,
        progress: Double = 0,
        error: String? = nil,
        segments: Int = 0
    ) -> String {
        BatchJobStatus.text(status: status, progress: progress, error: error, segmentCount: segments)
    }

    @Test("a job says where it is, in words")
    func statusReadsInWords() {
        #expect(text(.pending) == "Queued")
        let running = text(.transcribing, progress: 0.32)
        #expect(running.contains("32"))
        #expect(running.hasPrefix("Transcribing · "))
        #expect(text(.cancelled, progress: 0.4) == "Cancelled")
        #expect(text(.failed, error: "no audio track") == "Failed: no audio track")
        #expect(text(.failed) == "Failed")
        #expect(text(.done, segments: 12) == "Completed · 12 segments")
    }

    /// Rounding a fraction under a percent prints "0%", which reads as stuck rather than as starting.
    @Test("a job that has just started says so instead of showing a zero")
    func earlyProgressStaysWordy() {
        #expect(text(.transcribing, progress: 0.004) == "Transcribing…")
        #expect(text(.transcribing) == "Transcribing…")
    }

    @Test("only a job that is still going draws a bar")
    func onlyRunningJobsDrawABar() {
        #expect(!BatchJobStatus.showsProgress(.pending))
        #expect(BatchJobStatus.showsProgress(.transcribing))
        #expect(!BatchJobStatus.showsProgress(.done))
        #expect(!BatchJobStatus.showsProgress(.failed))
        #expect(!BatchJobStatus.showsProgress(.cancelled))
    }

    @Test("a row's ✕ cancels or removes that file alone")
    func cancelActsOnOneJob() {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("job-row-cancel")
        )
        let running = BatchJob(url: URL(fileURLWithPath: "/tmp/JobRowTests/a.wav"), status: .transcribing)
        let waiting = BatchJob(url: URL(fileURLWithPath: "/tmp/JobRowTests/b.wav"))
        let spare = BatchJob(url: URL(fileURLWithPath: "/tmp/JobRowTests/c.wav"))

        let oneJob = JobCancelAction.oneJob(status: .pending)
        #expect(oneJob.axID == "Row.Button.Cancel")
        #expect(JobCancelAction.oneJob(status: .transcribing).help != oneJob.help)
        model.batchJobs = [running, waiting, spare]
        oneJob.run(for: waiting.id, in: model)
        #expect(model.batchJobs.map(\.id) == [running.id, spare.id])
        #expect(model.batchJobs.map(\.status) == [.transcribing, .pending])
    }

    @Test("a row compares equal while what it draws is unchanged")
    func rowEqualityFollowsWhatItDraws() {
        var job = BatchJob(url: URL(fileURLWithPath: "/tmp/JobRowTests/take.wav"), status: .transcribing)
        let row = JobRow(job: job, cancel: .oneJob(status: .transcribing))
        #expect(JobRow(job: job, cancel: .oneJob(status: .transcribing)) == row)
        #expect(JobRow(job: job, isSelected: true, cancel: .oneJob(status: .transcribing)) != row)
        #expect(JobRow(job: job, listed: true, cancel: .oneJob(status: .transcribing)) != row)
        #expect(JobRow(job: job, cancel: .oneJob(status: .pending)) != row)
        job.status = .done
        #expect(JobRow(job: job, cancel: .oneJob(status: .transcribing)) != row)
    }

    @Test("a running job has no glyph, since its bar is the indicator")
    func statusGlyphsMatchTheState() {
        #expect(BatchJobStatus.symbol(for: .transcribing) == nil)
        #expect(BatchJobStatus.symbol(for: .done) == "checkmark.circle.fill")
        #expect(BatchJobStatus.symbol(for: .failed) == "exclamationmark.triangle.fill")
    }

    @Test("a row's tooltip covers the badge and text, not the trailing actions")
    func rowTooltipLeavesTheActionsAlone() throws {
        let path = #filePath.replacingOccurrences(of: "ParolaAppTests/EntryRowTests.swift", with: "ParolaApp/Views/Components/EntryRow.swift")
        let row = try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(row.contains("chromedRow .onHover"))
        #expect(row.components(separatedBy: ".help(rowHelp)").count - 1 == 3)
    }
}

@Suite("Reading column")
struct ReadingColumnTests {
    @Test("a row keeps the proportions the library page was designed on")
    func rowProportions() {
        #expect(EntryRowMetrics.height == 64)
        #expect(EntryRowMetrics.rowBadgeSide == 30)
        #expect(EntryRowMetrics.columnWidth == 820)
    }

    @Test("a pane wider than the column splits the rest into equal margins")
    func widePaneCentresTheColumn() {
        #expect(EntryRowMetrics.columnMargin(paneWidth: 1_440 - 240) == 190)
        #expect(EntryRowMetrics.columnMargin(paneWidth: 1_800 - 240) == 370)
    }

    @Test("a pane narrower than the column gets no margin")
    func narrowPaneKeepsItsWidth() {
        #expect(EntryRowMetrics.columnMargin(paneWidth: 700) == 0)
        #expect(EntryRowMetrics.columnMargin(paneWidth: 820) == 0)
        #expect(EntryRowMetrics.columnMargin(paneWidth: 0) == 0)
    }
}
