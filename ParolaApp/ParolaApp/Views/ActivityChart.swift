import Charts
import SwiftUI
import ParolaCore

struct ActivityChart: View {
    typealias Bucket = LibraryStatistics.ActivityBucket

    let buckets: [Bucket]
    let range: ActivityRange
    let caption: String

    static let height: CGFloat = 160

    @State private var hovered: Date?
    private let calendar = Calendar.current

    var body: some View {
        Chart {
            ForEach(buckets) { bucket in
                if bucket.entries > 0 {
                    BarMark(
                        x: .value("Date", bucket.start, unit: unit),
                        y: .value("Minutes", bucket.audioSeconds / 60)
                    )
                    .foregroundStyle(DS.Color.accent.opacity(opacity(of: bucket)))
                    .cornerRadius(2)
                }
            }
            if let bucket = hoveredBucket {
                RuleMark(x: .value("Hovered", bucket.start, unit: unit))
                    .foregroundStyle(DS.Palette.divider)
                    .annotation(
                        position: .top,
                        spacing: DS.Spacing.tight,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        card(for: bucket)
                    }
            }
        }
        .chartXSelection(value: $hovered)
        // Room for half of the last label: Charts drops a label that would cross the plot's trailing edge.
        .chartXScale(domain: domain, range: .plotDimension(endPadding: DS.Spacing.medium))
        .chartYScale(domain: 0...axis.top)
        .chartXAxis { xAxis }
        .chartYAxis { yAxis }
        .frame(height: Self.height)
        .accessibilityLabel(Text("Activity"))
        .accessibilityValue(caption)
        .axLeaf("Chart.Activity")
    }

    private var axis: ActivityAxis {
        ActivityAxis(maxMinutes: buckets.map { $0.audioSeconds / 60 }.max() ?? 0)
    }

    private var unit: Calendar.Component {
        range == .days30 ? .day : .month
    }

    private var domain: ClosedRange<Date> {
        guard let first = buckets.first?.start, let last = buckets.last?.start else {
            let now = Date()
            return now...now
        }
        return first...(calendar.date(byAdding: unit, value: 1, to: last) ?? last)
    }

    private var hoveredBucket: Bucket? {
        guard let hovered else { return nil }
        return buckets.last { $0.start <= hovered }
    }

    private func opacity(of bucket: Bucket) -> Double {
        guard let hoveredBucket else { return 1 }
        return hoveredBucket.id == bucket.id ? 1 : 0.75
    }

    /// Counted back from the last bucket, so today is always on the axis.
    private var labelledDates: [Date] {
        let every = range == .days30 ? 7 : 1
        return buckets.enumerated().compactMap { offset, bucket in
            (buckets.count - 1 - offset) % every == 0 ? middle(of: bucket) : nil
        }
    }

    private func middle(of bucket: Bucket) -> Date {
        guard let end = calendar.date(byAdding: unit, value: 1, to: bucket.start) else { return bucket.start }
        return bucket.start.addingTimeInterval(end.timeIntervalSince(bucket.start) / 2)
    }

    private func axisLabel(for date: Date) -> String {
        range == .days30 ? AppFormat.dayAndMonth(date) : AppFormat.month(date)
    }

    private func cardLabel(for date: Date) -> String {
        range == .days30 ? AppFormat.dayAndMonth(date) : AppFormat.monthAndYear(date)
    }

    private var xAxis: some AxisContent {
        AxisMarks(values: labelledDates) { value in
            if let date = value.as(Date.self) {
                // Charts sizes a label to the slot it computes, and one month's slot came out too narrow for "Jul".
                AxisValueLabel(collisionResolution: .disabled) {
                    Text(axisLabel(for: date))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                        .fixedSize()
                }
            }
        }
    }

    private var yAxis: some AxisContent {
        AxisMarks(position: .leading, values: axis.ticks) { value in
            AxisGridLine().foregroundStyle(DS.Palette.divider)
            if let minutes = value.as(Double.self), minutes > 0 {
                AxisValueLabel {
                    Text(axis.label(minutes))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }
        }
    }

    private func card(for bucket: Bucket) -> some View {
        Text(StatisticsCopy.bucket(
            label: cardLabel(for: bucket.start), entries: bucket.entries, audioSeconds: bucket.audioSeconds
        ))
        .font(DS.Font.secondary)
        .foregroundStyle(DS.Color.primaryText)
        .padding(.horizontal, DS.Spacing.small)
        .padding(.vertical, DS.Spacing.tight)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(DS.Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .strokeBorder(DS.Palette.divider, lineWidth: 1)
        )
    }
}

/// The chart's y axis: a baseline and up to three gridlines above it, all in one unit picked from the tallest bar.
struct ActivityAxis: Equatable {
    enum Unit: Equatable {
        case minutes
        case hours
    }

    let unit: Unit
    /// In minutes, ascending from zero; the last one is the top of the chart.
    let ticks: [Double]

    private static let minuteSteps: [Double] = [1, 2, 5, 10, 15, 20, 30, 60]
    private static let hourSteps: [Double] = [1, 1.5, 2, 3, 5]
    private static let hoursFrom = 180.0
    private static let emptyChartMinutes = 60.0
    private static let gridlines = 3.0

    init(maxMinutes: Double) {
        let max = maxMinutes.isFinite && maxMinutes > 0 ? maxMinutes : Self.emptyChartMinutes
        let unit: Unit = max < Self.hoursFrom ? .minutes : .hours
        let step = Self.step(covering: max, unit: unit)
        let count = Int((max / step).rounded(.up))
        self.unit = unit
        ticks = (0...count).map { Double($0) * step }
    }

    var top: Double { ticks.last ?? 0 }

    func label(_ minutes: Double, bundle: Bundle = .main, locale: Locale = AppFormat.locale) -> String {
        switch unit {
        case .minutes:
            let count = Int(minutes.rounded()).formatted(.number.locale(locale))
            return "\(count) \(String(localized: "min", bundle: bundle))"
        case .hours:
            let count = (minutes / 60).formatted(.number.precision(.fractionLength(0...1)).locale(locale))
            return "\(count) \(String(localized: "h", bundle: bundle))"
        }
    }

    private static func step(covering max: Double, unit: Unit) -> Double {
        let fits = { (step: Double) in (max / step).rounded(.up) <= gridlines }
        switch unit {
        case .minutes:
            return minuteSteps.first(where: fits) ?? 60
        case .hours:
            var scale = 60.0
            while true {
                if let step = hourSteps.map({ $0 * scale }).first(where: fits) { return step }
                scale *= 10
            }
        }
    }
}
