import SwiftUI
import ParolaCore

struct StatisticsView: View {
    @Environment(AppModel.self) private var model
    @State private var stats: LibraryStatistics?

    /// Seeded only by tests; in the app the `.task` fills it on the first pass.
    init(stats: LibraryStatistics? = nil) {
        _stats = State(initialValue: stats)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch StatisticsPageState(libraryIsEmpty: model.libraryEntries.isEmpty, stats: stats) {
            case .empty:
                EmptyStateView(
                    systemImage: "chart.bar",
                    title: "No Statistics Yet",
                    message: "Transcribe a file and its timing appears here."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .summary(let stats):
                summary(stats)
            case .waiting:
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.surface)
        .task(id: model.libraryVersion) {
            stats = LibraryStatistics.compute(entries: model.libraryEntries)
        }
        .axBranch("Statistics")
    }

    private var header: some View {
        PageHeader(
            title: "Statistics",
            subtitle: stats.map {
                StatisticsCopy.subtitle(entries: $0.totals.entries, audioSeconds: $0.totals.audioSeconds)
            }
        ) {
            EmptyView()
        }
    }

    private func summary(_ stats: LibraryStatistics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.large) {
                tiles(stats)
                // The caveat for the timed tiles and the table below, not a fact about the page.
                Text(StatisticsCopy.coverage(stats.timed))
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .axLeaf("Text.Coverage")
                if !stats.perModel.isEmpty {
                    modelTable(stats)
                }
                kinds(stats)
                recent(stats)
            }
            .padding(DS.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tiles(_ stats: LibraryStatistics) -> some View {
        LazyVGrid(columns: Self.tileColumns, spacing: DS.Spacing.regular) {
            StatTile(
                label: "Transcripts",
                value: AppFormat.integer(stats.totals.entries),
                axID: "Tile.Transcripts"
            )
            StatTile(
                label: "Audio transcribed",
                value: AppFormat.duration(seconds: stats.totals.audioSeconds),
                axID: "Tile.Audio"
            )
            StatTile(
                label: "Time transcribing",
                value: AppFormat.duration(seconds: stats.totals.transcriptionSeconds),
                axID: "Tile.Time"
            )
            StatTile(
                label: "Average speed",
                value: stats.averageSpeed.map { TranscriptionSpeed.label($0, locale: AppFormat.locale) } ?? "—",
                axID: "Tile.Speed"
            )
        }
    }

    /// Four across whatever the window gives them: an adaptive grid packs them left and leaves a gutter.
    private static let tileColumns = Array(
        repeating: GridItem(.flexible(minimum: 120), spacing: DS.Spacing.regular),
        count: 4
    )

    private func modelTable(_ stats: LibraryStatistics) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            SectionCaption("By Model")
            Grid(alignment: .leading, horizontalSpacing: DS.Spacing.regular, verticalSpacing: DS.Spacing.snug) {
                GridRow {
                    Text("Model")
                    columnHeading("Runs")
                    columnHeading("Audio")
                    columnHeading("Time")
                    columnHeading("Speed")
                    Color.clear.frame(width: ModelRowMetrics.barWidth, height: 1)
                }
                .font(DS.Font.caption)
                .textCase(.uppercase)
                .foregroundStyle(DS.Color.secondaryText)
                ForEach(stats.perModel) { row in
                    ModelTableRow(row: row, fastest: fastestSpeed(stats))
                }
            }
        }
    }

    private func kinds(_ stats: LibraryStatistics) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            SectionCaption("By Kind")
            HStack(spacing: DS.Spacing.regular) {
                ForEach(visibleCategories(stats), id: \.self) { category in
                    KindCount(category: category, count: stats.totals.count(category))
                }
            }
        }
    }

    private func recent(_ stats: LibraryStatistics) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            SectionCaption("Last 30 Days")
            Text(StatisticsCopy.last30Days(
                entries: stats.last30Days.entries,
                audioSeconds: stats.last30Days.audioSeconds
            ))
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.primaryText)
            .axLeaf("Text.Last30Days")
        }
    }

    private func visibleCategories(_ stats: LibraryStatistics) -> [EntryCategory] {
        EntryCategory.allCases.filter { category in
            switch category {
            case .transcription: return true
            case .meeting: return model.features.isEnabled(.meetings) || stats.totals.count(category) > 0
            case .dictation: return model.features.isEnabled(.dictation) || stats.totals.count(category) > 0
            }
        }
    }

    private func fastestSpeed(_ stats: LibraryStatistics) -> Double? {
        stats.perModel.compactMap(\.speed).max()
    }

    /// "ESECUZIONI" is half again as wide as "RUNS" and would take the header row to two lines.
    private func columnHeading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: ModelRowMetrics.numberWidth, alignment: .trailing)
    }
}

/// What the page draws: the numbers, the empty state, or — for the pass before `compute` has run —
/// nothing at all, since an empty state there would flash on every visit to a full library.
enum StatisticsPageState: Equatable {
    case empty
    case waiting
    case summary(LibraryStatistics)

    init(libraryIsEmpty: Bool, stats: LibraryStatistics?) {
        if libraryIsEmpty {
            self = .empty
        } else if let stats {
            self = .summary(stats)
        } else {
            self = .waiting
        }
    }
}

private enum ModelRowMetrics {
    static let numberWidth: CGFloat = 64
    static let barWidth: CGFloat = 72
}

private struct StatTile: View {
    let label: LocalizedStringKey
    let value: String
    let axID: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.tight) {
            Text(label)
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(DS.Font.title)
                .monospacedDigit()
                .foregroundStyle(DS.Color.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .axLeaf(axID)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.regular)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .fill(DS.Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .strokeBorder(DS.Palette.divider, lineWidth: 1)
        )
    }
}

private struct ModelTableRow: View {
    let row: LibraryStatistics.ModelRow
    let fastest: Double?

    var body: some View {
        GridRow {
            Text(AppModel.modelLabel(row.modelName))
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            number(AppFormat.integer(row.runs))
            number(AppFormat.duration(seconds: row.audioSeconds))
            number(AppFormat.duration(seconds: row.transcriptionSeconds))
            number(row.speed.map { TranscriptionSpeed.label($0, locale: AppFormat.locale) } ?? "")
            speedBar
        }
    }

    private func number(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.mono)
            .foregroundStyle(DS.Color.secondaryText)
            .frame(width: ModelRowMetrics.numberWidth, alignment: .trailing)
    }

    @ViewBuilder
    private var speedBar: some View {
        if let speed = row.speed, let fastest, fastest > 0 {
            DSProgressBar(value: speed / fastest, fill: DS.Color.accent.opacity(0.55), height: 4)
                .frame(width: ModelRowMetrics.barWidth)
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: ModelRowMetrics.barWidth, height: 4)
        }
    }
}

private struct KindCount: View {
    let category: EntryCategory
    let count: Int

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            Image(systemName: DS.categorySymbol(for: category))
                .font(DS.Font.body)
                .foregroundStyle(DS.categoryTint(for: category))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(AppFormat.integer(count))
                    .font(DS.Font.bodyStrong)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.primaryText)
                Text(title)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
            }
        }
    }

    private var title: LocalizedStringKey {
        switch category {
        case .transcription: return "Transcriptions"
        case .meeting: return "Meetings"
        case .dictation: return "Dictations"
        }
    }
}
