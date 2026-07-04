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
        .onChange(of: file) { _, _ in
            startDate = Date()
            settled = ""
        }
        .task(id: partial) {
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.easeOut(duration: 0.4)) { settled = partial }
        }
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

    private var streamingTranscript: Text {
        let parts = StreamingText.split(shown: settled, latest: partial)
        var text = AttributedString(parts.settled)
        text.foregroundColor = DS.Color.primaryText
        if !parts.fresh.isEmpty {
            var tail = AttributedString(parts.fresh)
            tail.foregroundColor = DS.Color.primaryText.opacity(0.5)
            text.append(tail)
        }
        return Text(text)
    }

    private var transcriptBox: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.regular) {
                    if hasText {
                        streamingTranscript
                            .font(DS.Font.transcript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .contentTransition(.interpolate)
                            .transition(.opacity)
                    }
                    SkeletonLines(count: hasText ? 3 : 6)
                        .id(Self.tailID)
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
