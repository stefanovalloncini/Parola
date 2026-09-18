import Foundation
import Testing
@testable import ParolaCore

@Suite("Library statistics")
struct LibraryStatisticsTests {
    private static let reference = Date(timeIntervalSince1970: 1_800_000_000)
    private static let calendar = Calendar(identifier: .gregorian)

    private func entry(
        _ id: String,
        category: EntryCategory = .transcription,
        model: String = "whisper",
        audio: Double? = 600,
        timing: Double? = nil,
        words: Int? = nil,
        daysAgo: Double = 0,
        deleted: Bool = false
    ) -> LibraryEntry {
        var manifest = ParolaDocument.Manifest(
            createdAt: Self.reference.addingTimeInterval(-daysAgo * 86_400),
            originalAudioName: "\(id).wav",
            modelName: model,
            language: "en",
            category: category,
            deletedAt: deleted ? Self.reference : nil,
            durationSeconds: audio
        )
        manifest.transcriptionSeconds = timing
        manifest.wordCount = words
        return LibraryEntry(id: id, bundleURL: URL(fileURLWithPath: "/tmp/\(id).parola"), manifest: manifest)
    }

    private func compute(_ entries: [LibraryEntry]) -> LibraryStatistics {
        LibraryStatistics.compute(entries: entries, now: Self.reference, calendar: Self.calendar)
    }

    @Test("an empty library adds up to nothing")
    func emptyLibrary() {
        let stats = compute([])
        #expect(stats.isEmpty)
        #expect(stats == .empty)
        #expect(stats.averageSpeed == nil)
        #expect(stats.longestRun == nil)
        #expect(stats.perModel.isEmpty)
    }

    @Test("entries in Recently Deleted are left out of every total")
    func deletedEntriesAreExcluded() {
        let stats = compute([
            entry("a", audio: 100, timing: 10, words: 50),
            entry("b", audio: 900, timing: 90, words: 400, deleted: true),
        ])
        #expect(stats.totals.entries == 1)
        #expect(stats.totals.audioSeconds == 100)
        #expect(stats.totals.words == 50)
        #expect(stats.timed.total == 1)
        #expect(stats.perModel.count == 1)
        #expect(stats.perModel.first?.runs == 1)
    }

    @Test("an untimed entry counts as a transcript but not as a measured run")
    func untimedEntryStillCounts() {
        let stats = compute([
            entry("old", audio: 300, timing: nil, words: 120, daysAgo: 400),
            entry("new", audio: 100, timing: 10, words: 80),
        ])
        #expect(stats.totals.entries == 2)
        #expect(stats.totals.audioSeconds == 400)
        #expect(stats.totals.words == 200)
        #expect(stats.totals.transcriptionSeconds == 10)
        #expect(stats.timed.count == 1)
        #expect(stats.timed.total == 2)
        #expect(stats.timed.coversEverything == false)
        #expect(stats.averageSpeed == 10)
        #expect(stats.perModel.count == 1)
        #expect(stats.perModel.first?.runs == 1)
    }

    @Test("timing starts at the oldest measured entry, not the oldest entry")
    func coverageStartsAtTheOldestMeasuredRun() {
        let stats = compute([
            entry("ancient", timing: nil, daysAgo: 500),
            entry("first-timed", timing: 30, daysAgo: 40),
            entry("later", timing: 20, daysAgo: 2),
        ])
        #expect(stats.timed.since == Self.reference.addingTimeInterval(-40 * 86_400))
    }

    @Test("models are listed heaviest first, each with its own speed")
    func perModelRowsAreSortedByRuns() {
        let stats = compute([
            entry("a", model: "parakeet", audio: 600, timing: 60),
            entry("b", model: "whisper", audio: 600, timing: 30),
            entry("c", model: "whisper", audio: 600, timing: 30),
            entry("d", model: "whisper", audio: 1200, timing: 60),
        ])
        #expect(stats.perModel.map(\.modelName) == ["whisper", "parakeet"])
        let whisper = stats.perModel[0]
        #expect(whisper.runs == 3)
        #expect(whisper.audioSeconds == 2400)
        #expect(whisper.transcriptionSeconds == 120)
        #expect(whisper.speed == 20)
        #expect(stats.perModel[1].speed == 10)
    }

    @Test("models with the same number of runs stay in a stable order")
    func tiesAreOrderedByName() {
        let stats = compute([
            entry("a", model: "zeta", timing: 10),
            entry("b", model: "alpha", timing: 10),
        ])
        #expect(stats.perModel.map(\.modelName) == ["alpha", "zeta"])
    }

    @Test("a zero-second run never divides by zero")
    func zeroSecondRunIsSafe() {
        let stats = compute([entry("instant", audio: 600, timing: 0, words: 10)])
        #expect(stats.timed.count == 1)
        #expect(stats.totals.transcriptionSeconds == 0)
        #expect(stats.averageSpeed == nil)
        #expect(stats.perModel.first?.speed == nil)
        #expect(stats.longestRun?.entryID == "instant")
    }

    @Test("an entry with no media duration cannot be given a speed")
    func missingAudioDurationHasNoSpeed() {
        let stats = compute([entry("no-media", audio: nil, timing: 12)])
        #expect(stats.totals.audioSeconds == 0)
        #expect(stats.averageSpeed == nil)
        #expect(stats.perModel.first?.speed == nil)
    }

    @Test("the longest run is the slowest measured entry")
    func longestRunIsTheSlowest() {
        let stats = compute([
            entry("quick", timing: 4),
            entry("slow", timing: 400),
            entry("untimed", timing: nil),
        ])
        #expect(stats.longestRun?.entryID == "slow")
        #expect(stats.longestRun?.seconds == 400)
    }

    @Test("the last thirty days count every entry made in them, timed or not")
    func lastThirtyDaysWindow() {
        let stats = compute([
            entry("today", audio: 100, timing: 10, daysAgo: 0),
            entry("just-inside", audio: 200, daysAgo: 29),
            entry("just-outside", audio: 400, daysAgo: 31),
        ])
        #expect(stats.last30Days.entries == 2)
        #expect(stats.last30Days.audioSeconds == 300)
    }

    @Test("counts are kept per category")
    func categoryCounts() {
        let stats = compute([
            entry("a", category: .transcription),
            entry("b", category: .meeting),
            entry("c", category: .meeting),
            entry("d", category: .dictation, deleted: true),
        ])
        #expect(stats.totals.count(.transcription) == 1)
        #expect(stats.totals.count(.meeting) == 2)
        #expect(stats.totals.count(.dictation) == 0)
        #expect(stats.totals.entries == 3)
    }

    @Test("average speed weighs the audio against the time it actually took")
    func averageSpeedIsWeighted() {
        let stats = compute([
            entry("a", audio: 600, timing: 60),
            entry("b", audio: 3000, timing: 60),
            entry("c", audio: 9000, timing: nil),
        ])
        #expect(stats.averageSpeed == 30)
    }
}

@Suite("Transcription speed")
struct TranscriptionSpeedTests {
    private let english = Locale(identifier: "en_US")

    @Test("the factor is audio over the time the run took")
    func factorIsAudioOverTime() {
        #expect(TranscriptionSpeed.factor(audioSeconds: 600, transcriptionSeconds: 37.5) == 16)
    }

    @Test("a missing, zero or nonsense value has no factor")
    func unmeasurableFactors() {
        #expect(TranscriptionSpeed.factor(audioSeconds: nil, transcriptionSeconds: 10) == nil)
        #expect(TranscriptionSpeed.factor(audioSeconds: 600, transcriptionSeconds: nil) == nil)
        #expect(TranscriptionSpeed.factor(audioSeconds: 600, transcriptionSeconds: 0) == nil)
        #expect(TranscriptionSpeed.factor(audioSeconds: 0, transcriptionSeconds: 10) == nil)
        #expect(TranscriptionSpeed.factor(audioSeconds: 600, transcriptionSeconds: .nan) == nil)
        #expect(TranscriptionSpeed.factor(audioSeconds: .infinity, transcriptionSeconds: 10) == nil)
    }

    @Test("a decimal below ten, a whole number above it")
    func labelPrecision() {
        #expect(TranscriptionSpeed.label(1.24, locale: english) == "1.2×")
        #expect(TranscriptionSpeed.label(9.94, locale: english) == "9.9×")
        #expect(TranscriptionSpeed.label(9.96, locale: english) == "10×")
        #expect(TranscriptionSpeed.label(10.04, locale: english) == "10×")
        #expect(TranscriptionSpeed.label(10, locale: english) == "10×")
        #expect(TranscriptionSpeed.label(16.4, locale: english) == "16×")
        #expect(TranscriptionSpeed.label(203.7, locale: english) == "204×")
    }

    @Test("the label follows the locale's decimal separator")
    func labelFollowsTheLocale() {
        #expect(TranscriptionSpeed.label(1.25, locale: Locale(identifier: "it_IT")) == "1,2×")
    }

    @Test("the real-time factor is the reciprocal, for tools that ask for it")
    func realTimeFactorIsTheReciprocal() throws {
        let rtf = try #require(TranscriptionSpeed.realTimeFactor(audioSeconds: 600, transcriptionSeconds: 30))
        #expect(abs(rtf - 0.05) < 1e-9)
        #expect(TranscriptionSpeed.realTimeFactor(audioSeconds: 600, transcriptionSeconds: 0) == nil)
    }
}
