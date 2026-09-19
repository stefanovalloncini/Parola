import SwiftUI

struct TranscribeScene: View {
    let demo: DemoPlayback

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            Text("It listens and writes.")
                .font(DS.Font.hero)
                .foregroundStyle(DS.Color.primaryText)
            Text("Every word stays on this Mac.")
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.secondaryText)
            DemoTranscriptCard(demo: demo)
                .padding(.top, DS.Spacing.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The live-transcription box, replayed from a recording instead of run by a model.
private struct DemoTranscriptCard: View {
    let demo: DemoPlayback

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barCount = 48

    private var script: DemoScript { demo.script }
    private var player: DemoPlayer? { demo.player }
    private var isPlaying: Bool { player?.isPlaying ?? false }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { _ in
            let time = demo.isSettled ? script.duration : (player?.currentTime ?? 0)
            VStack(alignment: .leading, spacing: DS.Spacing.regular) {
                meter(at: time)
                speakerLine
                transcript(at: time)
            }
        }
        .padding(DS.Spacing.large)
        .frame(maxWidth: .infinity, minHeight: DS.Size.liveTranscriptMinHeight, alignment: .topLeading)
        .cardBackground(radius: DS.Radius.large)
        .overlay(alignment: .bottomTrailing) {
            replayButton.animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: demo.isSettled)
        }
        .task {
            guard demo.autoplays else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            demo.start()
        }
        .onDisappear { demo.stop() }
    }

    private func meter(at time: Double) -> some View {
        HStack(spacing: DS.Spacing.regular) {
            WaveformHistory(
                samples: envelope(at: time),
                barWidth: 2,
                spacing: 2,
                maxHeight: 28,
                idleHeight: 3,
                fill: DS.Color.accent
            )
            Text(verbatim: clock(time))
                .font(DS.Font.mono)
                .foregroundStyle(DS.Color.secondaryText)
                .contentTransition(.numericText())
            Spacer()
            muteChip
        }
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

    private func transcript(at time: Double) -> some View {
        Text("\(Text(reveal(at: time)))\(StreamingReveal.caret(visible: showsCaret(at: time)))")
            .font(DS.Font.transcript)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(script.text)
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

    @ViewBuilder
    private var replayButton: some View {
        if demo.isSettled {
            Button("Replay") { demo.player?.replay() }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .axLeaf("Introduction.Button.Replay")
                .padding(DS.Spacing.large)
                .transition(.opacity)
        }
    }

    private func envelope(at time: Double) -> [Float] {
        guard isPlaying else { return Array(repeating: 0, count: Self.barCount) }
        return script.levels(window: Self.barCount, endingAt: time)
    }

    private func reveal(at time: Double) -> AttributedString {
        guard player != nil, !script.words.isEmpty, !demo.isSettled else {
            return StreamingReveal.attributed(settled: script.text, fresh: "")
        }
        let visible = script.words.prefix(script.visibleWordCount(at: time)).map(\.text)
        let freshCount = min(2, visible.count)
        let settled = visible.dropLast(freshCount).joined(separator: " ")
        let fresh = visible.suffix(freshCount).joined(separator: " ")
        return StreamingReveal.attributed(
            settled: settled,
            fresh: settled.isEmpty ? fresh : " " + fresh
        )
    }

    private func showsCaret(at time: Double) -> Bool {
        guard player != nil, !demo.isSettled else { return false }
        return reduceMotion || Int(time / StreamingReveal.caretBlinkPeriod) % 2 == 0
    }

    private func clock(_ time: Double) -> String {
        let seconds = Int(time)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
