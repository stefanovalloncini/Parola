import Foundation

/// The version `yt-dlp --version` prints. Releases are named after their date (`2026.03.17`), which is
/// what the age check reads.
public struct YtDlpVersion: Sendable, Equatable, CustomStringConvertible {
    /// yt-dlp warns past this age; sites like YouTube change often enough that older builds start failing.
    public static let staleAfterDays = 90

    public let text: String
    let releaseDay: Date?

    /// Nil unless the first line looks like a version, so a traceback or a banner never shows up as one.
    public init?(_ output: String) {
        let firstLine = output.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard firstLine.count <= 40,
              firstLine.range(of: #"^[0-9][0-9A-Za-z.+_-]*$"#, options: .regularExpression) != nil
        else { return nil }
        text = firstLine
        releaseDay = Self.releaseDay(of: firstLine)
    }

    public var description: String { text }

    /// yt-dlp's own rule: stale once the release day is more than 90 UTC calendar days behind today.
    public func isStale(asOf now: Date) -> Bool {
        guard let releaseDay,
              let cutoff = Self.utc.date(byAdding: .day, value: -Self.staleAfterDays, to: Self.utc.startOfDay(for: now))
        else { return false }
        return releaseDay < cutoff
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private static func releaseDay(of text: String) -> Date? {
        let parts = text.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3,
              parts[0].count == 4,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let date = utc.date(from: DateComponents(year: year, month: month, day: day))
        else { return nil }
        let parsed = utc.dateComponents([.year, .month, .day], from: date)
        guard parsed.year == year, parsed.month == month, parsed.day == day else { return nil }
        return date
    }
}

extension YtDlpVersion: LogSafe {
    public var logToken: String { text }
}
