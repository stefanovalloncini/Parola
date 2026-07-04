import SwiftUI
import ParolaCore

struct TranscribingPane: View {
    let file: URL
    let partial: String
    let progress: Double?

    @State private var eta = ETACalculator()
    @State private var etaLabel: String?
    @State private var startDate = Date()
    @State private var settled = ""
    @State private var isFinishing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let tailID = "transcribing.tail"
    private static let caretBlinkPeriod: Double = 0.6
    private static let finishingProgressThreshold = 0.9
    private static let finishingStallSeconds: Double = 3
    private var hasText: Bool { !partial.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            header
            transcriptBox
        }
        .padding(DS.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: progress) { _, newValue in
            updateETA(for: newValue)
            if isFinishing { withAnimation(.easeOut(duration: 0.25)) { isFinishing = false } }
        }
        .onChange(of: file) { _, _ in
            startDate = Date()
            settled = ""
            isFinishing = false
        }
        .task(id: partial) {
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.easeOut(duration: 0.4)) { settled = partial }
        }
        .task(id: progress) {
            guard let progress, progress >= Self.finishingProgressThreshold else { return }
            try? await Task.sleep(for: .seconds(Self.finishingStallSeconds))
            withAnimation(.easeInOut(duration: 0.3)) { isFinishing = true }
        }
        .onAppear { updateETA(for: progress) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(spacing: DS.Spacing.small) {
                Text("Transcribing \(file.lastPathComponent)…")
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.primaryText)
                Spacer()
                if isFinishing {
                    Text("Finishing…")
                        .font(DS.Font.captionMono)
                        .foregroundStyle(DS.Color.secondaryText)
                        .transition(.opacity)
                } else if let progress {
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
            if let progress, !isFinishing {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(DS.Color.accent)
            } else {
                ProgressView()
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

    private func streamingTranscript(caretVisible: Bool) -> Text {
        let parts = StreamingText.split(shown: settled, latest: partial)
        var text = AttributedString(parts.settled)
        text.foregroundColor = DS.Color.primaryText
        if !parts.fresh.isEmpty {
            var tail = AttributedString(parts.fresh)
            tail.foregroundColor = DS.Color.primaryText.opacity(0.5)
            text.append(tail)
        }
        return Text(text) + Text(verbatim: "\u{258F}")
            .foregroundStyle(DS.Color.accent.opacity(caretVisible ? 1 : 0))
    }

    private var transcriptBox: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.regular) {
                    if hasText {
                        TimelineView(.periodic(from: startDate, by: Self.caretBlinkPeriod)) { context in
                            let ticks = Int(context.date.timeIntervalSince(startDate) / Self.caretBlinkPeriod)
                            streamingTranscript(caretVisible: reduceMotion || ticks % 2 == 0)
                                .font(DS.Font.transcript)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .contentTransition(.interpolate)
                                .accessibilityLabel(partial)
                        }
                        .transition(.opacity)
                        .id(Self.tailID)
                    } else {
                        SkeletonLines(count: 6)
                            .id(Self.tailID)
                    }
                }
                .padding(DS.Spacing.large)
                .animation(.easeOut(duration: 0.28), value: partial)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: partial) { old, _ in
                settled = old
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(Self.tailID, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground(radius: DS.Radius.large)
    }
}
