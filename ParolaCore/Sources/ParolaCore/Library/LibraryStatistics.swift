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

        public init(entries: Int, byCategory: [EntryCategory: Int], audioSeconds: Double, transcriptionSeconds: Double, words: Int) {
            self.entries = entries
            self.byCategory = byCategory
            self.audioSeconds = audioSeconds
            self.transcriptionSeconds = transcriptionSeconds
            self.words = words
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

    public struct LongestRun: Equatable, Sendable {
        public let entryID: LibraryEntry.ID
        public let seconds: Double

        public init(entryID: LibraryEntry.ID, seconds: Double) {
            self.entryID = entryID
            self.seconds = seconds
        }
    }

    public let totals: Totals
    public let timed: Coverage
    /// Timed entries only, heaviest user first: a row without a measured run has nothing to compare.
    public let perModel: [ModelRow]
    public let last30Days: RecentWindow
    public let longestRun: LongestRun?
    public let averageSpeed: Double?

    public static let empty = LibraryStatistics(
        totals: Totals(entries: 0, byCategory: [:], audioSeconds: 0, transcriptionSeconds: 0, words: 0),
        timed: Coverage(count: 0, total: 0, since: nil),
        perModel: [],
        last30Days: RecentWindow(entries: 0, audioSeconds: 0),
        longestRun: nil,
        averageSpeed: nil
    )

    public init(
        totals: Totals,
        timed: Coverage,
        perModel: [ModelRow],
        last30Days: RecentWindow,
        longestRun: LongestRun?,
        averageSpeed: Double?
    ) {
        self.totals = totals
        self.timed = timed
        self.perModel = perModel
        self.last30Days = last30Days
        self.longestRun = longestRun
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
        var byCategory: [EntryCategory: Int] = [:]
        var audioSeconds = 0.0
        var words = 0
        var recentEntries = 0
        var recentAudio = 0.0
        var timedCount = 0
        var timedSeconds = 0.0
        var timedAudio = 0.0
        var since: Date?
        var longestRun: LongestRun?
        var modelOrder: [String] = []
        var models: [String: (runs: Int, audio: Double, seconds: Double)] = [:]

        for entry in active {
            byCategory[entry.category, default: 0] += 1
            let entryAudio = max(0, entry.durationSeconds ?? 0)
            audioSeconds += entryAudio
            words += max(0, entry.wordCount ?? 0)
            if entry.createdAt >= windowStart {
                recentEntries += 1
                recentAudio += entryAudio
            }
            guard let measured = entry.transcriptionSeconds, measured.isFinite, measured >= 0 else { continue }
            timedCount += 1
            timedSeconds += measured
            timedAudio += entryAudio
            if let earliest = since { since = min(earliest, entry.createdAt) } else { since = entry.createdAt }
            if measured > (longestRun?.seconds ?? -1) {
                longestRun = LongestRun(entryID: entry.id, seconds: measured)
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
                words: words
            ),
            timed: Coverage(count: timedCount, total: active.count, since: since),
            perModel: perModel,
            last30Days: RecentWindow(entries: recentEntries, audioSeconds: recentAudio),
            longestRun: longestRun,
            averageSpeed: TranscriptionSpeed.factor(
                audioSeconds: timedAudio, transcriptionSeconds: timedSeconds
            )
        )
    }
}
