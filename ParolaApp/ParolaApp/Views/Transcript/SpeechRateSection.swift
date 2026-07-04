import SwiftUI
import ParolaCore

struct SpeechRateSection: View {
    @Environment(AppModel.self) private var model

    private var bins: [SpeechRateBin] {
        guard let segments = model.transcript?.segments else { return [] }
        return SpeechRateSeries.compute(segments: segments, binSeconds: 30)
    }

    var body: some View {
        let bins = self.bins
        if bins.count >= 2 {
            InfoSection(title: "Speech rate") {
                let values = bins.map(\.wordsPerMinute)
                let maxValue = max(values.max() ?? 1, 1)
                let average = values.reduce(0, +) / Double(values.count)
                VStack(alignment: .leading, spacing: 6) {
                    SpeechRateSparkline(values: values, maxValue: maxValue)
                        .frame(height: 44)
                    HStack {
                        Text("Avg \(Int(average)) wpm")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.secondaryText)
                        Spacer()
                        Text("Peak \(Int(maxValue)) wpm")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                }
            }
        }
    }
}

private struct SpeechRateSparkline: View {
    let values: [Double]
    let maxValue: Double

    private static let lineWidth: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let step = values.count > 1 ? width / CGFloat(values.count - 1) : 0
            ZStack {
                Path { p in
                    guard !values.isEmpty else { return }
                    for (idx, value) in values.enumerated() {
                        let point = CGPoint(x: CGFloat(idx) * step, y: y(for: value, height: height))
                        if idx == 0 {
                            p.move(to: point)
                        } else {
                            p.addLine(to: point)
                        }
                    }
                }
                .stroke(DS.Color.accent, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))

                Path { p in
                    guard !values.isEmpty else { return }
                    p.move(to: CGPoint(x: 0, y: height))
                    for (idx, value) in values.enumerated() {
                        p.addLine(to: CGPoint(x: CGFloat(idx) * step, y: y(for: value, height: height)))
                    }
                    p.addLine(to: CGPoint(x: CGFloat(values.count - 1) * step, y: height))
                    p.closeSubpath()
                }
                .fill(DS.Color.accent.opacity(0.18))
            }
        }
    }

    private func y(for value: Double, height: CGFloat) -> CGFloat {
        SparklineGeometry.y(value: value, maxValue: maxValue, height: height, lineWidth: Self.lineWidth)
    }
}

enum SparklineGeometry {
    /// Maps a value to a vertical position, reserving half the stroke width at the top and
    /// bottom so a peak (or zero) bin's round-capped stroke stays inside the frame instead of
    /// clipping at the edge.
    static func y(value: Double, maxValue: Double, height: CGFloat, lineWidth: CGFloat) -> CGFloat {
        let inset = lineWidth / 2
        let usableHeight = max(height - lineWidth, 0)
        let fraction = maxValue > 0 ? value / maxValue : 0
        return inset + (1 - CGFloat(fraction)) * usableHeight
    }
}
