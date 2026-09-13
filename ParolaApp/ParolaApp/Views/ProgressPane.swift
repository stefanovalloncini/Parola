import SwiftUI
import ParolaCore

struct ProgressPane: View {
    let title: LocalizedStringKey
    let progress: Double?
    @Environment(AppModel.self) private var model
    @State private var eta = ETACalculator()
    @State private var etaLabel: String?
    @State private var startDate = Date()

    var body: some View {
        VStack(spacing: DS.Spacing.regular) {
            HStack {
                Text(title)
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.primaryText)
                Button("Cancel") { model.cancelCurrentWork() }
                    .controlSize(.small)
                    .axLeaf("Progress.Button.Cancel")
            }
            DSProgressBar(value: progress)
                .frame(width: 280)
            if let progress {
                HStack(spacing: DS.Spacing.tight) {
                    Text(AppFormat.percent(progress))
                        .contentTransition(.numericText())
                    if let etaLabel {
                        Text(verbatim: "·")
                            .foregroundStyle(DS.Color.accentText.opacity(0.6))
                        Text("\(etaLabel) left")
                    }
                }
                .accentPill()
            } else {
                TimelineView(.periodic(from: startDate, by: 1)) { context in
                    Text("\(ETACalculator.format(context.date.timeIntervalSince(startDate))) elapsed")
                        .monospacedDigit()
                }
                .accentPill()
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
