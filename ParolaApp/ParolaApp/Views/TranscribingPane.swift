import SwiftUI
import ParolaCore

struct TranscribingPane: View {
    let file: URL
    let partial: String
    let progress: Double?
    var expectsPartials: Bool = true
    var stage: TranscribeStage?

    @Environment(AppModel.self) private var model
    @State private var eta = ETACalculator()
    @State private var etaDeadline: Date?
    @State private var startDate = Date()
    @State private var settled = ""
    @State private var isFinishing = false
    @State private var isPreparing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private static let tailID = "transcribing.tail"
    private static let caretBlinkPeriod: Double = 0.6
    private static let finishingProgressThreshold = 0.9
    private static let finishingStallSeconds: Double = 3
    private static let preparingGraceSeconds: Double = 2.5
    private var hasText: Bool { !partial.isEmpty }
    private var awaitingFirstOutput: Bool { !hasText && progress == nil }
    private var showsPreparing: Bool {
        Self.showsPreparing(stage: stage, heuristic: isPreparing, awaitingFirstOutput: awaitingFirstOutput)
    }

    // The engine-reported stage wins; the grace-period heuristic only covers runs that never report one.
    static func showsPreparing(stage: TranscribeStage?, heuristic: Bool, awaitingFirstOutput: Bool) -> Bool {
        guard awaitingFirstOutput else { return false }
        if let stage { return stage == .preparingAudio }
        return heuristic
    }

    private var titleKey: LocalizedStringKey {
        showsPreparing
            ? "Preparing \(file.lastPathComponent)…"
            : "Transcribing \(file.lastPathComponent)…"
    }

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
            isPreparing = false
            eta.reset()
            etaDeadline = nil
        }
        .task(id: awaitingFirstOutput) {
            guard expectsPartials, awaitingFirstOutput else {
                if isPreparing { withAnimation(.easeOut(duration: 0.25)) { isPreparing = false } }
                return
            }
            try? await Task.sleep(for: .seconds(Self.preparingGraceSeconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { isPreparing = true }
        }
        .task(id: partial) {
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.easeOut(duration: 0.4)) { settled = partial }
        }
        .task(id: progress) {
            guard let progress, progress >= Self.finishingProgressThreshold else { return }
            try? await Task.sleep(for: .seconds(Self.finishingStallSeconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { isFinishing = true }
        }
        .onAppear { updateETA(for: progress) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(spacing: DS.Spacing.small) {
                Text(titleKey)
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.primaryText)
                    .contentTransition(.interpolate)
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
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: progress)
                    if let etaDeadline {
                        Text(verbatim: "·")
                            .foregroundStyle(DS.Color.secondaryText.opacity(0.5))
                        TimelineView(.periodic(from: startDate, by: 1)) { context in
                            let remaining = max(0, etaDeadline.timeIntervalSince(context.date))
                            Text("\(ETACalculator.format(remaining)) left")
                                .font(DS.Font.captionMono)
                                .foregroundStyle(DS.Color.secondaryText)
                                .monospacedDigit()
                        }
                    }
                } else {
                    TimelineView(.periodic(from: startDate, by: 1)) { context in
                        Text("\(ETACalculator.format(context.date.timeIntervalSince(startDate))) elapsed")
                            .font(DS.Font.captionMono)
                            .foregroundStyle(DS.Color.secondaryText)
                            .monospacedDigit()
                    }
                }
                Button("Cancel") { model.cancelCurrentWork() }
                    .controlSize(.small)
                    .axLeaf("Transcribing.Button.Cancel")
            }
            if let progress, !isFinishing {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(DS.Color.accent)
                    .animation(.easeOut(duration: 0.5), value: progress)
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
            etaDeadline = nil
            return
        }
        eta.observe(progress: value)
        etaDeadline = eta.projectedFinish()
    }

    private var transcriptBodyText: Text {
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

    private func caret(visible: Bool) -> Text {
        Text(verbatim: "\u{258F}")
            .foregroundStyle(DS.Color.accent.opacity(visible ? 1 : 0))
    }

    private var transcriptBox: some View {
        let bodyText = transcriptBodyText
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.regular) {
                    if hasText {
                        TimelineView(.periodic(from: startDate, by: Self.caretBlinkPeriod)) { context in
                            let ticks = Int(context.date.timeIntervalSince(startDate) / Self.caretBlinkPeriod)
                            (bodyText + caret(visible: reduceMotion || ticks % 2 == 0))
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
            .mask { topFadeMask }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground(radius: DS.Radius.large)
    }

    @ViewBuilder private var topFadeMask: some View {
        if hasText && !reduceTransparency {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: DS.Spacing.large)
                Color.black
            }
        } else {
            Color.black
        }
    }
}
