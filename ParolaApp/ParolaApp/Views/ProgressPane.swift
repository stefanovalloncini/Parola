import SwiftUI
import ParolaCore

struct ProgressPane: View {
    let title: LocalizedStringKey
    let progress: Double?
    @State private var eta = ETACalculator()
    @State private var etaLabel: String?
    @State private var startDate = Date()

    var body: some View {
        VStack(spacing: DS.Spacing.regular) {
            Text(title)
                .font(DS.Font.heading)
                .foregroundStyle(DS.Color.primaryText)
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(DS.Color.accent)
                    .frame(width: 280)
                HStack(spacing: 8) {
                    Text("\(Int(progress * 100))%")
                        .font(DS.Font.captionMono)
                        .foregroundStyle(DS.Color.secondaryText)
                    if let etaLabel {
                        Text(verbatim: "·")
                            .foregroundStyle(DS.Color.secondaryText.opacity(0.5))
                        Text("\(etaLabel) left")
                            .font(DS.Font.captionMono)
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                }
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(DS.Color.accent)
                    .frame(width: 280)
                TimelineView(.periodic(from: startDate, by: 1)) { context in
                    Text("\(ETACalculator.format(context.date.timeIntervalSince(startDate))) elapsed")
                        .font(DS.Font.captionMono)
                        .foregroundStyle(DS.Color.secondaryText)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: progress) { _, newValue in
            updateETA(for: newValue)
            if newValue == nil { startDate = Date() }
        }
        .onAppear { updateETA(for: progress) }
    }

    private func updateETA(for value: Double?) {
        guard let value else {
            eta.reset()
            etaLabel = nil
            return
        }
        eta.observe(progress: value)
        if let seconds = eta.remainingSeconds(), seconds > 1 {
            etaLabel = ETACalculator.format(seconds)
        } else if value >= 1 {
            etaLabel = "0:00"
        } else {
            etaLabel = nil
        }
    }
}
