import SwiftUI
import ParolaCore

struct TranscribingPane: View {
    let file: URL
    var name: String?
    let partial: String
    let progress: Double?
    var expectsPartials: Bool = true
    var stage: TranscribeStage?

    @Environment(AppModel.self) private var model
    @State private var eta = ETACalculator()
    @State private var etaDeadline: Date?
    @State private var startDate = Date()
    @State private var shown = ""
    @State private var bodyText = AttributedString()
    @State private var isFinishing = false
    @State private var isPreparing = false
    @State private var streamedTextHeight: CGFloat = 0
    @State private var isOnScreen = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private static let tailID = "transcribing.tail"
    private static let displayWindowChars = 2000
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

    private var recordedTake: AppModel.RecordedTake? {
        guard let take = model.recordedTake, take.file == file else { return nil }
        return take
    }

    /// A take is named by its title, and a link's captions arrive with no file of their own, so the site stands in.
    private var shownName: String {
        if let name { return name }
        if let recordedTake { return recordedTake.title }
        guard !file.isFileURL else { return file.lastPathComponent }
        return LinkDownloadFailure.site(for: file) ?? file.absoluteString
    }

    private var titleKey: LocalizedStringKey {
        showsPreparing
            ? "Preparing \(shownName)…"
            : "Transcribing \(shownName)…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            header
            // Priority over the spacer, or the stack splits the leftover height and the box halves.
            transcriptBox
                .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: progress) { _, newValue in
            updateETA(for: newValue)
            if isFinishing { withAnimation(.easeOut(duration: 0.25)) { isFinishing = false } }
        }
        .onChange(of: file) { _, _ in
            startDate = Date()
            shown = ""
            bodyText = AttributedString()
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
            let window = StreamingText.tail(of: partial, maxChars: Self.displayWindowChars)
            withAnimation(.easeOut(duration: 0.4)) { bodyText = StreamingReveal.attributed(settled: window, fresh: "") }
        }
        .task(id: progress) {
            guard let progress, progress >= Self.finishingProgressThreshold else { return }
            try? await Task.sleep(for: .seconds(Self.finishingStallSeconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { isFinishing = true }
        }
        .onAppear {
            updateETA(for: progress)
            updateBodyText(for: partial)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(spacing: DS.Spacing.small) {
                Text(titleKey)
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.primaryText)
                    .contentTransition(.interpolate)
                Spacer()
                readout.accentPill()
                if recordedTake != nil {
                    Button("Stop Transcribing") { model.stopTranscribingTake() }
                        .controlSize(.small)
                        .help("The recording stays in your library.")
                        .axLeaf("Transcribing.Button.StopTranscribing")
                } else {
                    Button("Cancel") { model.cancelCurrentWork() }
                        .controlSize(.small)
                        .axLeaf("Transcribing.Button.Cancel")
                }
            }
            DSProgressBar(value: isFinishing ? nil : progress)
        }
    }

    @ViewBuilder
    private var readout: some View {
        if isFinishing {
            Text("Finishing…")
                .transition(.opacity)
        } else if let progress {
            HStack(spacing: DS.Spacing.tight) {
                Text(AppFormat.percent(progress))
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : DS.Motion.progress, value: progress)
                if let etaDeadline {
                    Text(verbatim: "·")
                        .foregroundStyle(DS.Color.accentInk.opacity(0.6))
                    TimelineView(.periodic(from: startDate, by: 1)) { context in
                        let remaining = max(0, etaDeadline.timeIntervalSince(context.date))
                        Text("\(ETACalculator.format(remaining)) left")
                            .monospacedDigit()
                    }
                }
            }
        } else {
            TimelineView(.periodic(from: startDate, by: 1)) { context in
                Text("\(ETACalculator.format(context.date.timeIntervalSince(startDate))) elapsed")
                    .monospacedDigit()
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

    private func updateBodyText(for latest: String) {
        let window = StreamingText.tail(of: latest, maxChars: Self.displayWindowChars)
        let parts = StreamingText.split(shown: shown, latest: window)
        shown = window
        bodyText = StreamingReveal.attributed(settled: parts.settled, fresh: parts.fresh)
    }

    private var transcriptBox: some View {
        TranscribingBox(textHeight: streamedTextHeight) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.regular) {
                        if hasText {
                            TranscribingText(text: bodyText, spoken: partial, blinks: isOnScreen)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.opacity)
                                .id(Self.tailID)
                        } else {
                            SkeletonLines(count: 6)
                                .id(Self.tailID)
                        }
                    }
                    .padding(DS.Spacing.large)
                    .animation(.easeOut(duration: 0.28), value: hasText)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(key: StreamedTextHeight.self, value: geometry.size.height)
                        }
                    )
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: partial) { _, newValue in
                    updateBodyText(for: newValue)
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(Self.tailID, anchor: .bottom)
                    }
                }
                .mask { topFadeMask }
            }
            .onPreferenceChange(StreamedTextHeight.self) { streamedTextHeight = $0 }
        }
        .animation(reduceMotion ? nil : DS.Motion.resize, value: streamedTextHeight)
        .cardBackground(radius: DS.Radius.large)
        .background(WindowShownReader { isOnScreen = $0 })
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

/// The run's words so far, selectable, the newest settling in with a fade, and the caret after them.
struct TranscribingText: View {
    @Environment(\.serifTranscript) private var serif
    let text: AttributedString
    let spoken: String
    let blinks: Bool

    var body: some View {
        Text("\(Text(text))\(LiveCaret.placeholder)")
            .font(DS.Font.transcript(serif: serif))
            .lineSpacing(DS.Spacing.transcriptLeading)
            .textSelection(.enabled)
            .contentTransition(.interpolate)
            .accessibilityLabel(spoken)
            .liveCaret(font: DS.Font.transcript(serif: serif), blinks: blinks)
    }
}

/// The box the run's words scroll in: it grows with them up to the height the pane has left, and answers the window's size checks without laying them out.
struct TranscribingBox<Content: View>: View {
    let textHeight: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        OfferedSize { content }
            .frame(
                maxWidth: .infinity,
                minHeight: DS.Size.liveTranscriptMinHeight,
                maxHeight: max(DS.Size.liveTranscriptMinHeight, textHeight)
            )
    }
}

/// Takes a size it is offered without measuring its child, so the window's size checks don't lay out the run's text again.
struct OfferedSize: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let width = proposal.width, let height = proposal.height else {
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }

    // The default asks the child for its guides, which measures it.
    func explicitAlignment(
        of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGFloat? {
        nil
    }

    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGFloat? {
        nil
    }
}

private struct StreamedTextHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
