import Foundation

/// The plain-text report `parola library stats` prints and `parola_library_stats` answers with.
public enum LibraryStatsReport {
    private typealias Totals = LibraryStatistics.Totals

    public static func text(_ stats: LibraryStatistics, locale: Locale = TranscriptionSpeed.toolLocale) -> String {
        guard !stats.isEmpty else { return "The library is empty." }
        var lines = [
            "Transcripts: \(stats.totals.entries)",
            "Audio: \(TranscriptionSpeed.duration(seconds: stats.totals.audioSeconds, locale: locale))",
            "Words: \(words(stats.totals))",
            "Time transcribing: \(TranscriptionSpeed.duration(seconds: stats.totals.transcriptionSeconds, locale: locale))",
            "Timed: \(coverage(stats.timed))",
        ]
        if let speed = stats.averageSpeed {
            lines.append("Average speed: \(TranscriptionSpeed.label(speed, locale: locale)) real time")
        }
        if let longest = stats.longestRun {
            lines.append("Longest run: \(TranscriptionSpeed.duration(seconds: longest.seconds, locale: locale)) (\(longest.entryID))")
        }
        lines.append("Last 30 days: \(stats.last30Days.entries) transcripts, \(TranscriptionSpeed.duration(seconds: stats.last30Days.audioSeconds, locale: locale))")
        lines.append(EntryCategory.allCases.map { "\(plural($0)): \(stats.totals.count($0))" }.joined(separator: ", "))
        if !stats.perModel.isEmpty {
            lines.append("")
            lines.append("By model")
            for row in stats.perModel {
                var parts = [
                    row.runs == 1 ? "1 run" : "\(row.runs) runs",
                    "\(TranscriptionSpeed.duration(seconds: row.audioSeconds, locale: locale)) audio",
                    "\(TranscriptionSpeed.duration(seconds: row.transcriptionSeconds, locale: locale)) spent",
                ]
                if let speed = row.speed {
                    parts.append("\(TranscriptionSpeed.label(speed, locale: locale)) real time")
                }
                lines.append("  \(row.modelName): \(parts.joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The word count has the same pre-change gap timing has, so it says what it covers when it is short.
    private static func words(_ totals: Totals) -> String {
        guard totals.wordsCountedFor != totals.entries else { return "\(totals.words)" }
        return "\(totals.words) (counted for \(totals.wordsCountedFor) of \(totals.entries))"
    }

    private static func plural(_ category: EntryCategory) -> String {
        switch category {
        case .transcription: return "Transcriptions"
        case .meeting: return "Meetings"
        case .dictation: return "Dictations"
        }
    }

    private static func coverage(_ timed: LibraryStatistics.Coverage) -> String {
        guard let since = timed.since, timed.count > 0 else { return "0 of \(timed.total)" }
        return "\(timed.count) of \(timed.total), since \(day(since))"
    }

    /// A fixed `yyyy-MM-dd` in UTC, so this line and `--json`'s ISO timestamp name the same day.
    private static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
