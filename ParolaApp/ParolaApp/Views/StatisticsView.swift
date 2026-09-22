import SwiftUI
import ParolaCore

struct StatisticsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stats: LibraryStatistics?
    @State private var activityRange: ActivityRange = .days30

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
            prominence: .display,
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
                Text(StatisticsCopy.coverage(
                    stats.timed, wordsCountedFor: stats.totals.wordsCountedFor, entries: stats.totals.entries
                ))
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .axLeaf("Text.Coverage")
                activity(stats)
                if !stats.perModel.isEmpty {
                    modelTable(stats)
                }
                records(stats)
                kinds(stats)
            }
            .padding(DS.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One row of five where they fit, otherwise three and two: a lone tile on its own row is never an option.
    private func tiles(_ stats: LibraryStatistics) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: TileGrid.spacing) {
                tileViews(stats)
            }
            LazyVGrid(columns: TileGrid.wrappedColumns, spacing: TileGrid.spacing) {
                tileViews(stats)
            }
        }
    }

    @ViewBuilder
    private func tileViews(_ stats: LibraryStatistics) -> some View {
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
        StatTile(
            label: "Words",
            value: stats.totals.wordsCountedFor == 0 ? "—" : AppFormat.integer(stats.totals.words),
            axID: "Tile.Words"
        )
    }

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
                let fastest = fastestSpeed(stats)
                ForEach(stats.perModel) { row in
                    ModelTableRow(row: row, fastest: fastest)
                }
            }
        }
    }

    @ViewBuilder
    private func records(_ stats: LibraryStatistics) -> some View {
        let records = StatisticsRecord.records(from: stats, entry: model.libraryEntry(id:))
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.tight) {
                SectionCaption("Records")
                VStack(spacing: 0) {
                    ForEach(records) { record in
                        RecordRow(record: record, showsAITitle: model.showAITitles, open: model.loadEntry)
                    }
                }
                .padding(.horizontal, -DS.Spacing.small)
            }
        }
    }

    private func kinds(_ stats: LibraryStatistics) -> some View {
        let categories = visibleCategories(stats)
        let shares = KindShare.shares(counts: categories.map { ($0, stats.totals.count($0)) })
        return VStack(alignment: .leading, spacing: DS.Spacing.small) {
            SectionCaption("By Kind")
            if categories.count > 1, !shares.isEmpty {
                KindShareBar(shares: shares)
            }
            HStack(spacing: DS.Spacing.regular) {
                ForEach(categories, id: \.self) { category in
                    KindCount(category: category, count: stats.totals.count(category))
                }
            }
        }
    }

    private func activity(_ stats: LibraryStatistics) -> some View {
        let buckets = activityRange == .days30 ? stats.dailyActivity : stats.monthlyActivity
        let caption = StatisticsCopy.activity(
            range: activityRange,
            entries: buckets.reduce(0) { $0 + $1.entries },
            audioSeconds: buckets.reduce(0) { $0 + $1.audioSeconds }
        )
        return VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack {
                SectionCaption("Activity")
                Spacer()
                Picker(selection: rangeSelection) {
                    Text("30 Days").tag(ActivityRange.days30)
                    Text("12 Months").tag(ActivityRange.months12)
                } label: {
                    Text("Activity")
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .fixedSize()
                .axLeaf("Picker.ActivityRange")
            }
            ActivityChart(buckets: buckets, range: activityRange, caption: caption)
            Text(caption)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.primaryText)
                .axLeaf(activityRange == .days30 ? "Text.Last30Days" : "Text.Last12Months")
        }
    }

    private var rangeSelection: Binding<ActivityRange> {
        Binding(
            get: { activityRange },
            set: { range in withAnimation(reduceMotion ? nil : DS.Motion.route) { activityRange = range } }
        )
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

    private func columnHeading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .fixedSize()
            .gridColumnAlignment(.trailing)
    }
}

/// What the page draws; nothing at all before `compute` has run, so the empty state can't flash on a full library.
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
    static let barWidth: CGFloat = 72
}

enum TileGrid {
    static let count = 5
    static let tileMinimum: CGFloat = 150
    static let spacing = DS.Spacing.regular
    static let wrappedColumns = Array(
        repeating: GridItem(.flexible(minimum: tileMinimum), spacing: spacing),
        count: 3
    )

    /// What `ViewThatFits` picks: the single row when its ideal width fits, else the three-column grid.
    static func columns(fitting width: CGFloat) -> Int {
        CGFloat(count) * tileMinimum + CGFloat(count - 1) * spacing <= width ? count : wrappedColumns.count
    }

    static func leavesLoneTile(width: CGFloat) -> Bool {
        let columns = columns(fitting: width)
        return count > columns && count % columns == 1
    }
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
        // The ideal width is what `ViewThatFits` measures; the text inside scales down rather than widening the tile.
        .frame(minWidth: TileGrid.tileMinimum, idealWidth: TileGrid.tileMinimum, maxWidth: .infinity)
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
            .lineLimit(1)
            .fixedSize()
            .gridColumnAlignment(.trailing)
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
