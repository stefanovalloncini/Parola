import SwiftUI
import ParolaCore

struct StatisticsRecord: Identifiable, Equatable {
    enum Kind: CaseIterable {
        case longestTranscript
        case longestRun
        case fastestRun

        var title: LocalizedStringKey {
            switch self {
            case .longestTranscript: return "Longest transcript"
            case .longestRun: return "Longest run"
            case .fastestRun: return "Fastest run"
            }
        }

        var axID: String {
            switch self {
            case .longestTranscript: return "Row.LongestTranscript"
            case .longestRun: return "Row.LongestRun"
            case .fastestRun: return "Row.FastestRun"
            }
        }
    }

    let kind: Kind
    let entry: LibraryEntry
    let value: String

    var id: Kind { kind }

    /// The rows the page can show: a record whose entry is no longer in the library has nothing to open.
    static func records(
        from stats: LibraryStatistics,
        entry lookup: (LibraryEntry.ID) -> LibraryEntry?,
        bundle: Bundle = .main,
        locale: Locale = AppFormat.locale
    ) -> [StatisticsRecord] {
        var records: [StatisticsRecord] = []
        if let longest = stats.longestTranscript, let entry = lookup(longest.entryID) {
            records.append(StatisticsRecord(
                kind: .longestTranscript, entry: entry, value: AppFormat.duration(seconds: longest.seconds, locale: locale)
            ))
        }
        if let run = stats.longestRun, let entry = lookup(run.entryID) {
            records.append(StatisticsRecord(
                kind: .longestRun, entry: entry, value: AppFormat.duration(seconds: run.seconds, locale: locale)
            ))
        }
        if let fastest = stats.fastestRun, let entry = lookup(fastest.entryID),
           let speed = StatisticsCopy.speed(fastest.speed, bundle: bundle, locale: locale) {
            records.append(StatisticsRecord(kind: .fastestRun, entry: entry, value: speed))
        }
        return records
    }
}

struct RecordRow: View {
    let record: StatisticsRecord
    let showsAITitle: Bool
    let open: (LibraryEntry.ID) -> Void

    static let labelWidth: CGFloat = 150
    static let valueWidth: CGFloat = 120

    @State private var hovered = false

    func activate() {
        open(record.entry.id)
    }

    var body: some View {
        Button(action: activate) {
            HStack(spacing: DS.Spacing.regular) {
                Text(record.kind.title)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(1)
                    .frame(width: Self.labelWidth, alignment: .leading)
                Text(record.value)
                    .font(DS.Font.bodyStrong)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.primaryText)
                    .lineLimit(1)
                    .frame(width: Self.valueWidth, alignment: .leading)
                Text(LibraryEntryDisplay.listTitle(for: record.entry, showsAITitle: showsAITitle))
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.snug)
            .rowChrome(selected: false, hovered: hovered, selection: .native)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovered = $0 }
        .axLeaf(record.kind.axID)
    }
}
