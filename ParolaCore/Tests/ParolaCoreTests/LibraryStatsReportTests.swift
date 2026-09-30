import Foundation
import Testing
@testable import ParolaCore

@Suite("Library stats report")
struct LibraryStatsReportTests {
    private let english = Locale(identifier: "en_US")

    private func entry(
        _ id: String,
        model: String,
        audio: Double,
        timing: Double?,
        words: Int?,
        at createdAt: Date = Date(timeIntervalSince1970: 1_757_635_200)
    ) -> LibraryEntry {
        var manifest = ParolaDocument.Manifest(
            createdAt: createdAt,
            originalAudioName: "\(id).wav",
            modelName: model,
            language: "en",
            durationSeconds: audio
        )
        manifest.transcriptionSeconds = timing
        manifest.wordCount = words
        return LibraryEntry(id: id, bundleURL: URL(fileURLWithPath: "/tmp/\(id).parola"), manifest: manifest)
    }

    @Test("an empty library says so instead of printing zeroes")
    func emptyLibraryReport() {
        #expect(LibraryStatsReport.text(.empty, locale: english) == "The library is empty.")
    }

    @Test("the report names the totals, the coverage and every model")
    func reportNamesTheTotals() {
        let stats = LibraryStatistics.compute(
            entries: [
                entry("a", model: "whisper", audio: 600, timing: 37.5, words: 900),
                entry("b", model: "whisper", audio: 600, timing: 37.5, words: 900),
                entry("c", model: "parakeet", audio: 600, timing: nil, words: 900),
            ],
            now: Date(timeIntervalSince1970: 1_757_635_200),
            calendar: Calendar(identifier: .gregorian)
        )
        let text = LibraryStatsReport.text(stats, locale: english)

        #expect(text.contains("Transcripts: 3"))
        #expect(text.contains("Audio: 30 min 00 s"))
        #expect(text.contains("Words: 2700"))
        #expect(!text.contains("counted for"), "every entry carries a count here")
        #expect(text.contains("Time transcribing: 1 min 15 s"))
        #expect(text.contains("Timed: 2 of 3, since 2025-09-12"))
        #expect(text.contains("Average speed: 16× real time"))
        #expect(text.contains("Longest run: 38 s (a)"))
        #expect(text.contains("Longest transcript: 10 min 00 s (a)"), "the first of three equal transcripts")
        #expect(text.contains("Fastest run: 16× real time (a)"))
        #expect(text.contains("Transcriptions: 3, Meetings: 0, Dictations: 0"))
        #expect(text.contains("  whisper: 2 runs"))
        #expect(LibraryStatsReport.text(stats).contains("2 runs"), "the tool locale is the default")
        #expect(!text.contains("parakeet"), "a model with no measured run has nothing to compare")
    }

    @Test("an untimed library still names its longest transcript, but no run")
    func recordsWithoutTiming() {
        let stats = LibraryStatistics.compute(
            entries: [
                entry("short", model: "whisper", audio: 90, timing: nil, words: nil),
                entry("long", model: "whisper", audio: 4_000, timing: nil, words: nil),
            ],
            now: Date(timeIntervalSince1970: 1_757_635_200),
            calendar: Calendar(identifier: .gregorian)
        )
        let text = LibraryStatsReport.text(stats, locale: english)
        #expect(text.contains("Longest transcript: 1 h 06 min 40 s (long)"))
        #expect(!text.contains("Longest run"))
        #expect(!text.contains("Fastest run"))
        #expect(!text.contains("activity"), "the buckets are for the chart and --json, not the text")
    }

    /// The text line and `--json`'s ISO timestamp are read together; a local zone makes them disagree near midnight.
    @Test("the coverage date is the UTC day, the one the JSON timestamp names")
    func coverageDateIsUTC() {
        // 2025-09-12T23:30:00Z: still the 12th in UTC, already the 13th in Rome.
        let lateAtNight = Date(timeIntervalSince1970: 1_757_719_800)
        let stats = LibraryStatistics.compute(
            entries: [entry("a", model: "whisper", audio: 600, timing: 30, words: 10, at: lateAtNight)],
            now: lateAtNight,
            calendar: Calendar(identifier: .gregorian)
        )
        #expect(LibraryStatsReport.text(stats, locale: english).contains("since 2025-09-12"))
    }

    @Test("the word total names its coverage when some entries predate the count")
    func wordCoverageIsPrinted() {
        let stats = LibraryStatistics.compute(
            entries: [
                entry("a", model: "whisper", audio: 600, timing: 30, words: 900),
                entry("b", model: "whisper", audio: 600, timing: nil, words: nil),
            ],
            now: Date(timeIntervalSince1970: 1_757_635_200),
            calendar: Calendar(identifier: .gregorian)
        )
        #expect(LibraryStatsReport.text(stats, locale: english).contains("Words: 900 (counted for 1 of 2)"))
    }

    @Test("a run reports its own wall time and speed in one line")
    func runSummaryLine() {
        #expect(
            TranscriptionSpeed.runSummary(seconds: 37, audioSeconds: 592, locale: english)
                == "Transcribed in 37 s (16× real time)"
        )
        #expect(
            TranscriptionSpeed.runSummary(seconds: 37, audioSeconds: 592, showsRealTimeFactor: true, locale: english)
                == "Transcribed in 37 s (16× real time, RTF 0.06)"
        )
        #expect(
            TranscriptionSpeed.runSummary(seconds: 125, audioSeconds: nil, locale: english)
                == "Transcribed in 2 min 05 s"
        )
        #expect(
            TranscriptionSpeed.runSummary(seconds: 12_500, audioSeconds: nil, locale: english)
                == "Transcribed in 3 h 28 min 20 s"
        )
        #expect(
            TranscriptionSpeed.runSummary(seconds: 0.48, audioSeconds: 7.6, locale: english)
                == "Transcribed in <1 s (16× real time)"
        )
    }
}

@Suite("CLI library stats", .serialized, .enabled(if: parolaBinaryURL != nil), .tags(.fileSystem))
struct CLIStatsProcessTests {
    private func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-cli-stats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func seed(_ library: URL) async throws -> (timed: LibraryEntry, untimed: LibraryEntry) {
        let store = LibraryStore(libraryURL: library, extraIndexer: nil)
        var transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 600, text: "sei parole in tutto qui dentro")],
            language: "it",
            modelName: "openai_whisper-tiny",
            durationSeconds: 600,
            transcriptionSeconds: 37.5
        )
        let timed = try await store.add(transcript: transcript, audioSource: nil, title: "Timed")
        transcript.transcriptionSeconds = nil
        transcript.durationSeconds = 1200
        let untimed = try await store.add(transcript: transcript, audioSource: nil, title: "Untimed")
        return (timed, untimed)
    }

    private func localDay(_ date: Date) -> (day: String, month: String) {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let month = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        return (month + String(format: "-%02d", parts.day ?? 0), month)
    }

    @Test("stats reports the totals and the coverage of a seeded library")
    func statsReportsTotals() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let library = scratch.appendingPathComponent("library", isDirectory: true)
        try await seed(library)

        let run = try await runParola(["library", "stats", "--library", library.path], timeout: 60)

        #expect(run.status == 0)
        #expect(run.stdout.contains("Transcripts: 2"))
        #expect(run.stdout.contains("Timed: 1 of 2, since "))
        #expect(run.stdout.contains("Average speed: 16× real time"))
        #expect(run.stdout.contains("Longest transcript: 20 min 00 s ("), "the untimed entry qualifies")
        #expect(run.stdout.contains("Fastest run: 16× real time ("))
        #expect(run.stdout.contains("By model"))
        #expect(run.stdout.contains("1 run,"), "a single run is not '1 runs'")
    }

    @Test("--json answers with the same numbers a script can read")
    func statsJSON() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let library = scratch.appendingPathComponent("library", isDirectory: true)
        let seeded = try await seed(library)

        let run = try await runParola(["library", "stats", "--library", library.path, "--json"], timeout: 60)

        #expect(run.status == 0)
        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any]
        )
        #expect(payload["transcripts"] as? Int == 2)
        #expect(payload["timed"] as? Int == 1)
        #expect((payload["audioSeconds"] as? Double) == 1800)
        #expect((payload["averageSpeed"] as? Double) == 16)
        #expect((payload["byModel"] as? [[String: Any]])?.count == 1)
        #expect((payload["longestRunSeconds"] as? Double) == 37.5)
        #expect(payload["longestRunEntry"] as? String == seeded.timed.id)
        #expect((payload["longestTranscriptSeconds"] as? Double) == 1200)
        #expect(payload["longestTranscriptEntry"] as? String == seeded.untimed.id)
        #expect((payload["fastestRunSpeed"] as? Double) == 16)
        #expect(payload["fastestRunEntry"] as? String == seeded.timed.id)

        let today = localDay(Date())
        let days = try #require(payload["dailyActivity"] as? [[String: Any]])
        #expect(days.count == 30)
        #expect(days.last?["day"] as? String == today.day)
        #expect(days.last?["entries"] as? Int == 2)
        #expect((days.last?["audioSeconds"] as? Double) == 1800)
        #expect(days.first?["entries"] as? Int == 0)
        let months = try #require(payload["monthlyActivity"] as? [[String: Any]])
        #expect(months.count == 12)
        #expect(months.last?["month"] as? String == today.month)
        #expect(months.last?["entries"] as? Int == 2)
        #expect(months.first?["entries"] as? Int == 0)
    }

    @Test("an empty library reports nothing rather than zeroes")
    func statsOnAnEmptyLibrary() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let run = try await runParola([
            "library", "stats", "--library", scratch.appendingPathComponent("library").path,
        ], timeout: 60)

        #expect(run.status == 0)
        #expect(run.stdout.contains("The library is empty."))
    }
}
