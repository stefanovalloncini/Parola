import SwiftUI

struct TranscribeScene: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            Text("It listens and writes.")
                .font(DS.Font.hero)
                .foregroundStyle(DS.Color.primaryText)
            Text("Every word stays on this Mac.")
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.secondaryText)
            DemoTranscriptCard(clip: DemoClip.bundled())
                .padding(.top, DS.Spacing.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The live-transcription box, replayed from a recording instead of run by a model.
private struct DemoTranscriptCard: View {
    let clip: DemoClip?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player: DemoPlayer?

    private var script: DemoScript { clip?.script ?? .placeholder }
    private var isFinished: Bool { player?.isFinished ?? false }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !(player?.isPlaying ?? false))) { _ in
            let time = isFinished ? script.duration : (player?.currentTime ?? 0)
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
            replayButton.animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: isFinished)
        }
        .task {
            guard let clip else { return }
            if player == nil { player = try? DemoPlayer(url: clip.audioURL) }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            player?.play()
        }
        .onDisappear { player?.stop() }
    }

    private func meter(at time: Double) -> some View {
        HStack(spacing: DS.Spacing.regular) {
            WaveformHistory(
                level: script.level(at: time),
                capacity: 48,
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
        .disabled(player == nil)
        .axLeaf("Introduction.Button.Mute")
    }

    @ViewBuilder
    private var replayButton: some View {
        if isFinished {
            Button("Replay") { player?.replay() }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .axLeaf("Introduction.Button.Replay")
                .padding(DS.Spacing.large)
                .transition(.opacity)
        }
    }

    private func reveal(at time: Double) -> AttributedString {
        guard player != nil, !script.words.isEmpty, !isFinished else {
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
        guard player != nil, !isFinished else { return false }
        return reduceMotion || Int(time / StreamingReveal.caretBlinkPeriod) % 2 == 0
    }

    private func clock(_ time: Double) -> String {
        let seconds = Int(time)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
