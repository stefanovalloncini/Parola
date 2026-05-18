import SwiftUI
import ParolaCore

struct SpeechRateSection: View {
    @EnvironmentObject var model: AppModel

    private var bins: [SpeechRateBin] {
        guard let segments = model.transcript?.segments else { return [] }
        return SpeechRateSeries.compute(segments: segments, binSeconds: 30)
    }

    var body: some View {
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

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let step = values.count > 1 ? width / CGFloat(values.count - 1) : 0
            ZStack {
                Path { p in
                    guard !values.isEmpty else { return }
                    for (idx, value) in values.enumerated() {
                        let x = CGFloat(idx) * step
                        let y = height - CGFloat(value / maxValue) * height
                        if idx == 0 {
                            p.move(to: CGPoint(x: x, y: y))
                        } else {
                            p.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(DS.Color.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                Path { p in
                    guard !values.isEmpty else { return }
                    p.move(to: CGPoint(x: 0, y: height))
                    for (idx, value) in values.enumerated() {
                        let x = CGFloat(idx) * step
                        let y = height - CGFloat(value / maxValue) * height
                        p.addLine(to: CGPoint(x: x, y: y))
                    }
                    p.addLine(to: CGPoint(x: CGFloat(values.count - 1) * step, y: height))
                    p.closeSubpath()
                }
                .fill(DS.Color.accent.opacity(0.18))
            }
        }
    }
}
