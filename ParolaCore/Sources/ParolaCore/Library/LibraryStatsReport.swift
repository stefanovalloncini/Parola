import Foundation

/// The plain-text report `parola library stats` prints and `parola_library_stats` answers with.
public enum LibraryStatsReport {
    public static func text(_ stats: LibraryStatistics, locale: Locale = TranscriptionSpeed.toolLocale) -> String {
        guard !stats.isEmpty else { return "The library is empty." }
        var lines = [
            "Transcripts: \(stats.totals.entries)",
            "Audio: \(Timecode.format(stats.totals.audioSeconds))",
            "Words: \(stats.totals.words)",
            "Time transcribing: \(Timecode.format(stats.totals.transcriptionSeconds))",
            "Timed: \(coverage(stats.timed))",
        ]
        if let speed = stats.averageSpeed {
            lines.append("Average speed: \(TranscriptionSpeed.label(speed, locale: locale)) real time")
        }
        if let longest = stats.longestRun {
            lines.append("Longest run: \(Timecode.format(longest.seconds)) (\(longest.entryID))")
        }
        lines.append("Last 30 days: \(stats.last30Days.entries) transcripts, \(Timecode.format(stats.last30Days.audioSeconds))")
        lines.append(EntryCategory.allCases.map { "\(plural($0)): \(stats.totals.count($0))" }.joined(separator: ", "))
        if !stats.perModel.isEmpty {
            lines.append("")
            lines.append("By model")
            for row in stats.perModel {
                var parts = [
                    row.runs == 1 ? "1 run" : "\(row.runs) runs",
                    "\(Timecode.format(row.audioSeconds)) audio",
                    "\(Timecode.format(row.transcriptionSeconds)) spent",
                ]
                if let speed = row.speed {
                    parts.append("\(TranscriptionSpeed.label(speed, locale: locale)) real time")
                }
                lines.append("  \(row.modelName): \(parts.joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n")
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

    /// A fixed `yyyy-MM-dd`, not a locale date: this output is read by scripts as often as by people.
    private static func day(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
