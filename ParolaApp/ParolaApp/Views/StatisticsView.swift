import SwiftUI
import ParolaCore

struct StatisticsView: View {
    @Environment(AppModel.self) private var model
    @State private var stats = LibraryStatistics.empty

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if stats.isEmpty {
                EmptyStateView(
                    systemImage: "chart.bar",
                    title: "No Statistics Yet",
                    message: "Transcribe a file and its timing appears here."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                summary
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
            subtitle: StatisticsCopy.subtitle(
                entries: stats.totals.entries,
                audioSeconds: stats.totals.audioSeconds
            )
        ) {
            EmptyView()
        }
    }

    private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.large) {
                tiles
                // Under the tiles rather than in the subtitle: it is the caveat for the two timed
                // tiles and the model table below it, not a fact about the page.
                Text(StatisticsCopy.coverage(stats.timed))
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .axLeaf("Text.Coverage")
                if !stats.perModel.isEmpty {
                    modelTable
                }
                kinds
                recent
            }
            .padding(DS.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var tiles: some View {
        LazyVGrid(columns: Self.tileColumns, spacing: DS.Spacing.regular) {
            StatTile(
                label: "Transcripts",
                value: AppFormat.integer(stats.totals.entries),
                axID: "Tile.Transcripts"
            )
            StatTile(
                label: "Audio transcribed",
                value: durationValue(stats.totals.audioSeconds),
                axID: "Tile.Audio"
            )
            StatTile(
                label: "Time transcribing",
                value: durationValue(stats.totals.transcriptionSeconds),
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

    private var modelTable: some View {
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
                    ModelTableRow(row: row, fastest: fastestSpeed)
                }
            }
        }
    }

    private var kinds: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            SectionCaption("By Kind")
            HStack(spacing: DS.Spacing.regular) {
                ForEach(visibleCategories, id: \.self) { category in
                    KindCount(category: category, count: stats.totals.count(category))
                }
            }
        }
    }

    private var recent: some View {
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

    private var visibleCategories: [EntryCategory] {
        EntryCategory.allCases.filter { category in
            switch category {
            case .transcription: return true
            case .meeting: return model.features.isEnabled(.meetings) || stats.totals.count(category) > 0
            case .dictation: return model.features.isEnabled(.dictation) || stats.totals.count(category) > 0
            }
        }
    }

    private var fastestSpeed: Double? {
        stats.perModel.compactMap(\.speed).max()
    }

    private func durationValue(_ seconds: Double) -> String {
        AppFormat.duration(seconds: seconds) ?? AppFormat.runDuration(seconds: 0)
    }

    private func columnHeading(_ title: LocalizedStringKey) -> some View {
        Text(title).frame(width: ModelRowMetrics.numberWidth, alignment: .trailing)
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
            number(AppFormat.duration(seconds: row.audioSeconds) ?? "")
            number(AppFormat.duration(seconds: row.transcriptionSeconds) ?? "")
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
