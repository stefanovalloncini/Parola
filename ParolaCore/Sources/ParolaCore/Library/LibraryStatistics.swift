import Foundation

/// What the library adds up to, read from the manifests alone so no transcript.json is opened.
/// Entries in Recently Deleted are left out — the user already threw them away.
public struct LibraryStatistics: Equatable, Sendable {
    public struct Totals: Equatable, Sendable {
        public let entries: Int
        public let byCategory: [EntryCategory: Int]
        public let audioSeconds: Double
        /// Summed over the timed entries only; `coverage` says how many of the library those are.
        public let transcriptionSeconds: Double
        public let words: Int
        /// How many of `entries` carry a word count at all; the rest were written before it was recorded.
        public let wordsCountedFor: Int

        public init(
            entries: Int,
            byCategory: [EntryCategory: Int],
            audioSeconds: Double,
            transcriptionSeconds: Double,
            words: Int,
            wordsCountedFor: Int = 0
        ) {
            self.entries = entries
            self.byCategory = byCategory
            self.audioSeconds = audioSeconds
            self.transcriptionSeconds = transcriptionSeconds
            self.words = words
            self.wordsCountedFor = wordsCountedFor
        }

        public func count(_ category: EntryCategory) -> Int { byCategory[category] ?? 0 }
    }

    /// How much of the library carries a measured run, and the oldest entry that does.
    public struct Coverage: Equatable, Sendable {
        public let count: Int
        public let total: Int
        public let since: Date?

        public init(count: Int, total: Int, since: Date?) {
            self.count = count
            self.total = total
            self.since = since
        }

        public var coversEverything: Bool { count == total }
    }

    public struct ModelRow: Equatable, Sendable, Identifiable {
        public var id: String { modelName }
        public let modelName: String
        public let runs: Int
        public let audioSeconds: Double
        public let transcriptionSeconds: Double

        public init(modelName: String, runs: Int, audioSeconds: Double, transcriptionSeconds: Double) {
            self.modelName = modelName
            self.runs = runs
            self.audioSeconds = audioSeconds
            self.transcriptionSeconds = transcriptionSeconds
        }

        public var speed: Double? {
            TranscriptionSpeed.factor(audioSeconds: audioSeconds, transcriptionSeconds: transcriptionSeconds)
        }
    }

    public struct RecentWindow: Equatable, Sendable {
        public let entries: Int
        public let audioSeconds: Double

        public init(entries: Int, audioSeconds: Double) {
            self.entries = entries
            self.audioSeconds = audioSeconds
        }
    }

    /// One calendar day or month of activity: the transcripts made in it and the audio they carry.
    public struct ActivityBucket: Equatable, Sendable, Identifiable {
        public let start: Date
        public let entries: Int
        public let audioSeconds: Double

        public init(start: Date, entries: Int, audioSeconds: Double) {
            self.start = start
            self.entries = entries
            self.audioSeconds = audioSeconds
        }

        public var id: Date { start }
    }

    public struct LongestRun: Equatable, Sendable {
        public let entryID: LibraryEntry.ID
        public let seconds: Double

        public init(entryID: LibraryEntry.ID, seconds: Double) {
            self.entryID = entryID
            self.seconds = seconds
        }
    }

    /// The entry with the most audio behind it; a run need not have been timed to hold it.
    public struct LongestTranscript: Equatable, Sendable {
        public let entryID: LibraryEntry.ID
        public let seconds: Double

        public init(entryID: LibraryEntry.ID, seconds: Double) {
            self.entryID = entryID
            self.seconds = seconds
        }
    }

    /// The timed entry that ran the most times faster than real time.
    public struct FastestRun: Equatable, Sendable {
        public let entryID: LibraryEntry.ID
        public let speed: Double

        public init(entryID: LibraryEntry.ID, speed: Double) {
            self.entryID = entryID
            self.speed = speed
        }
    }

    public let totals: Totals
    public let timed: Coverage
    /// Timed entries only, heaviest user first: a row without a measured run has nothing to compare.
    public let perModel: [ModelRow]
    public let last30Days: RecentWindow
    /// Thirty calendar days ending today, then twelve calendar months ending this month, both zero-filled and in order.
    public let dailyActivity: [ActivityBucket]
    public let monthlyActivity: [ActivityBucket]
    public let longestRun: LongestRun?
    public let longestTranscript: LongestTranscript?
    public let fastestRun: FastestRun?
    public let averageSpeed: Double?

    public static let empty = LibraryStatistics(
        totals: Totals(entries: 0, byCategory: [:], audioSeconds: 0, transcriptionSeconds: 0, words: 0),
        timed: Coverage(count: 0, total: 0, since: nil),
        perModel: [],
        last30Days: RecentWindow(entries: 0, audioSeconds: 0),
        dailyActivity: [],
        monthlyActivity: [],
        longestRun: nil,
        longestTranscript: nil,
        fastestRun: nil,
        averageSpeed: nil
    )

    public init(
        totals: Totals,
        timed: Coverage,
        perModel: [ModelRow],
        last30Days: RecentWindow,
        dailyActivity: [ActivityBucket],
        monthlyActivity: [ActivityBucket],
        longestRun: LongestRun?,
        longestTranscript: LongestTranscript?,
        fastestRun: FastestRun?,
        averageSpeed: Double?
    ) {
        self.totals = totals
        self.timed = timed
        self.perModel = perModel
        self.last30Days = last30Days
        self.dailyActivity = dailyActivity
        self.monthlyActivity = monthlyActivity
        self.longestRun = longestRun
        self.longestTranscript = longestTranscript
        self.fastestRun = fastestRun
        self.averageSpeed = averageSpeed
    }

    public var isEmpty: Bool { totals.entries == 0 }

    public static func compute(
        entries: [LibraryEntry],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> LibraryStatistics {
        let active = entries.filter { $0.deletedAt == nil }
        guard !active.isEmpty else { return .empty }

        let windowStart = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? today
        let firstMonth = calendar.date(byAdding: .month, value: -11, to: thisMonth) ?? thisMonth
        var days = [Tally](repeating: Tally(), count: 30)
        var months = [Tally](repeating: Tally(), count: 12)
        var byCategory: [EntryCategory: Int] = [:]
        var audioSeconds = 0.0
        var words = 0
        var wordsCountedFor = 0
        var recentEntries = 0
        var recentAudio = 0.0
        var timedCount = 0
        var timedSeconds = 0.0
        var timedAudio = 0.0
        var since: Date?
        var longestRun: LongestRun?
        var longestTranscript: LongestTranscript?
        var fastestRun: FastestRun?
        var modelOrder: [String] = []
        var models: [String: (runs: Int, audio: Double, seconds: Double)] = [:]

        for entry in active {
            byCategory[entry.category, default: 0] += 1
            let entryAudio = max(0, entry.durationSeconds ?? 0)
            audioSeconds += entryAudio
            if let counted = entry.wordCount {
                words += max(0, counted)
                wordsCountedFor += 1
            }
            if entry.createdAt >= windowStart {
                recentEntries += 1
                recentAudio += entryAudio
            }
            if entry.createdAt >= firstDay,
               let day = calendar.dateComponents([.day], from: firstDay, to: calendar.startOfDay(for: entry.createdAt)).day,
               days.indices.contains(day) {
                days[day].add(entryAudio)
            }
            if entry.createdAt >= firstMonth,
               let month = calendar.dateComponents([.month], from: firstMonth, to: entry.createdAt).month,
               months.indices.contains(month) {
                months[month].add(entryAudio)
            }
            if entryAudio > (longestTranscript?.seconds ?? 0) {
                longestTranscript = LongestTranscript(entryID: entry.id, seconds: entryAudio)
            }
            guard let measured = entry.transcriptionSeconds, measured.isFinite, measured >= 0 else { continue }
            timedCount += 1
            timedSeconds += measured
            timedAudio += entryAudio
            if let earliest = since { since = min(earliest, entry.createdAt) } else { since = entry.createdAt }
            if measured > (longestRun?.seconds ?? -1) {
                longestRun = LongestRun(entryID: entry.id, seconds: measured)
            }
            if let speed = TranscriptionSpeed.factor(audioSeconds: entryAudio, transcriptionSeconds: measured),
               speed > (fastestRun?.speed ?? 0) {
                fastestRun = FastestRun(entryID: entry.id, speed: speed)
            }
            if models[entry.modelName] == nil { modelOrder.append(entry.modelName) }
            var row = models[entry.modelName] ?? (0, 0, 0)
            row.runs += 1
            row.audio += entryAudio
            row.seconds += measured
            models[entry.modelName] = row
        }

        let perModel = modelOrder
            .map { name -> ModelRow in
                let row = models[name] ?? (0, 0, 0)
                return ModelRow(
                    modelName: name, runs: row.runs, audioSeconds: row.audio, transcriptionSeconds: row.seconds
                )
            }
            .sorted { ($0.runs, $1.modelName) > ($1.runs, $0.modelName) }

        return LibraryStatistics(
            totals: Totals(
                entries: active.count,
                byCategory: byCategory,
                audioSeconds: audioSeconds,
                transcriptionSeconds: timedSeconds,
                words: words,
                wordsCountedFor: wordsCountedFor
            ),
            timed: Coverage(count: timedCount, total: active.count, since: since),
            perModel: perModel,
            last30Days: RecentWindow(entries: recentEntries, audioSeconds: recentAudio),
            dailyActivity: days.enumerated().map { offset, tally in
                tally.bucket(at: calendar.date(byAdding: .day, value: offset, to: firstDay) ?? firstDay)
            },
            monthlyActivity: months.enumerated().map { offset, tally in
                tally.bucket(at: calendar.date(byAdding: .month, value: offset, to: firstMonth) ?? firstMonth)
            },
            longestRun: longestRun,
            longestTranscript: longestTranscript,
            fastestRun: fastestRun,
            averageSpeed: TranscriptionSpeed.factor(
                audioSeconds: timedAudio, transcriptionSeconds: timedSeconds
            )
        )
    }

    private struct Tally {
        var entries = 0
        var audioSeconds = 0.0

        mutating func add(_ audio: Double) {
            entries += 1
            audioSeconds += audio
        }

        func bucket(at start: Date) -> ActivityBucket {
            ActivityBucket(start: start, entries: entries, audioSeconds: audioSeconds)
        }
    }
}
