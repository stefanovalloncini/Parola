import SwiftUI

/// The live-transcription box, replayed from a recording instead of run by a model: the brand bars are its meter and the words land one by one.
struct DemoTranscriptCard: View {
    let demo: DemoPlayback
    let brand: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barsSide: CGFloat = 88

    private var script: DemoScript { demo.script }
    private var summary: DemoTranscriptSummary { DemoTranscriptSummary(script: script) }
    private var player: DemoPlayer? { demo.player }
    private var isPlaying: Bool { player?.isPlaying ?? false }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { _ in
            let time = demo.isSettled ? script.duration : (player?.currentTime ?? 0)
            VStack(alignment: .leading, spacing: DS.Spacing.regular) {
                header(at: time)
                speakerLine
                words(at: time)
                if demo.isSettled {
                    footer.transition(footerTransition)
                }
            }
            .animation(settleAnimation, value: demo.isSettled)
        }
        .padding(DS.Spacing.large)
        .frame(maxWidth: .infinity, minHeight: DS.Size.demoTranscriptMinHeight, alignment: .topLeading)
        .cardBackground(radius: DS.Radius.large)
        .task {
            guard demo.autoplays else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            demo.start()
        }
        .onDisappear { demo.stop() }
    }

    private func header(at time: Double) -> some View {
        HStack(spacing: DS.Spacing.regular) {
            BrandWaveform(side: Self.barsSide, drive: drive(at: time))
                .brandBars(in: brand)
            Text(verbatim: clock(at: time))
                .font(DS.Font.mono)
                .foregroundStyle(DS.Color.secondaryText)
                .contentTransition(reduceMotion ? .identity : .numericText())
            if demo.isSettled {
                replayButton
            }
            Spacer()
            muteChip
        }
    }

    /// Under reduce motion the mark stays the static icon while the words still land: a level meter is the most kinetic thing in the introduction.
    private func drive(at time: Double) -> BrandWaveform.Drive {
        isPlaying && !reduceMotion ? .levels(script.barLevels(at: time)) : .breathing
    }

    private var speakerLine: some View {
        HStack(spacing: DS.Spacing.small) {
            Circle()
                .fill(DS.speakerColor(for: script.speaker))
                .frame(width: 8, height: 8)
            Text(verbatim: script.speaker)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
        }
    }

    @ViewBuilder
    private func words(at time: Double) -> some View {
        if script.words.isEmpty {
            Text(verbatim: script.text)
                .font(DS.Font.transcript)
                .lineSpacing(DS.Spacing.transcriptLeading)
                .foregroundStyle(DS.Color.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            wordFlow(visible: visibleWordCount(at: time), caretLit: caretIsLit(at: time))
        }
    }

    private func wordFlow(visible: Int, caretLit: Bool) -> some View {
        let freshFrom = max(0, visible - 2)
        return LeadingFlow(spacing: DS.Spacing.tight, rowSpacing: DS.Spacing.transcriptLeading) {
            ForEach(script.words.indices.prefix(visible), id: \.self) { index in
                Text(verbatim: script.words[index].text)
                    .font(DS.Font.transcript)
                    .foregroundStyle(DS.Color.primaryText)
                    .opacity(index >= freshFrom && !demo.isSettled ? StreamingReveal.freshOpacity : 1)
                    .transition(wordTransition)
            }
            if showsCaret {
                StreamingReveal.caret(visible: caretLit).font(DS.Font.transcript)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(wordAnimation, value: visible)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(script.text)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            Rectangle()
                .fill(DS.Palette.divider)
                .frame(height: 1)
            HStack(spacing: DS.Spacing.small) {
                summaryLine
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                Spacer()
                Text("Export as")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                ForEach(DemoTranscriptSummary.exportFormats) { format in
                    Text(DemoTranscriptSummary.label(for: format))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.primaryText)
                        .chipChrome(isSelected: false, size: .compact, style: .subtle)
                }
            }
        }
    }

    private var summaryLine: some View {
        HStack(spacing: DS.Spacing.tight) {
            Text(verbatim: summary.wordCount == nil ? summary.durationLabel : "\(summary.durationLabel) ·")
            if let count = summary.wordCount {
                Text("\(count) words")
            }
        }
    }

    private var muteChip: some View {
        let muted = player?.isMuted ?? false
        let hint: LocalizedStringKey = muted ? "Unmute" : "Mute"
        return Button {
            player?.isMuted.toggle()
        } label: {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .buttonStyle(DSIconChipButtonStyle())
        .help(hint)
        .accessibilityLabel(hint)
        .disabled(player == nil)
        .axLeaf("Introduction.Button.Mute")
    }

    private var replayButton: some View {
        Button("Replay") { demo.player?.replay() }
            .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
            .axLeaf("Introduction.Button.Replay")
            .transition(.opacity)
    }

    private var wordTransition: AnyTransition {
        .asymmetric(
            insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)),
            removal: .identity
        )
    }

    private var wordAnimation: Animation {
        reduceMotion ? DS.Motion.rowState : .spring(response: 0.35, dampingFraction: 0.85)
    }

    private var footerTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6))
    }

    private var settleAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85)
    }

    private var showsCaret: Bool {
        player != nil && !demo.isSettled
    }

    private func visibleWordCount(at time: Double) -> Int {
        guard player != nil, !demo.isSettled else { return script.words.count }
        return script.visibleWordCount(at: time)
    }

    private func caretIsLit(at time: Double) -> Bool {
        reduceMotion || Int(time / StreamingReveal.caretBlinkPeriod) % 2 == 0
    }

    /// Counts up while the clip runs, then states the clip's length the way the footer does.
    private func clock(at time: Double) -> String {
        guard !demo.isSettled else { return summary.durationLabel }
        let seconds = Int(time)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
