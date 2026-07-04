import SwiftUI
import ParolaCore

struct TranscribingPane: View {
    let file: URL
    let partial: String
    let progress: Double?

    @State private var eta = ETACalculator()
    @State private var etaLabel: String?
    @State private var startDate = Date()

    private static let tailID = "transcribing.tail"
    private var hasText: Bool { !partial.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            header
            transcriptBox
        }
        .padding(DS.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: progress) { _, newValue in updateETA(for: newValue) }
        .onChange(of: file) { _, _ in startDate = Date() }
        .onAppear { updateETA(for: progress) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(spacing: DS.Spacing.small) {
                if progress == nil {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(DS.Color.accent)
                }
                Text("Transcribing \(file.lastPathComponent)…")
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.primaryText)
                Spacer()
                if let progress {
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
                } else {
                    TimelineView(.periodic(from: startDate, by: 1)) { context in
                        Text("\(ETACalculator.format(context.date.timeIntervalSince(startDate))) elapsed")
                            .font(DS.Font.captionMono)
                            .foregroundStyle(DS.Color.secondaryText)
                            .monospacedDigit()
                    }
                }
            }
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(DS.Color.accent)
            }
        }
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

    private var transcriptBox: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.regular) {
                    if hasText {
                        Text(partial)
                            .font(DS.Font.transcript)
                            .foregroundStyle(DS.Color.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .transition(.opacity)
                    }
                    SkeletonLines(count: hasText ? 3 : 6)
                        .id(Self.tailID)
                }
                .padding(DS.Spacing.large)
                .animation(.easeOut(duration: 0.28), value: partial)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: partial) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(Self.tailID, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground(radius: DS.Radius.large)
    }
}
