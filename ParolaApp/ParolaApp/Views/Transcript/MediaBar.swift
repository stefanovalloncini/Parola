import SwiftUI
import AVKit

struct MediaBar: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("playbackRate") private var playbackRate: Double = 1.0
    @State private var scrubbingTo: Double?

    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        let duration = model.transcript?.durationSeconds ?? 0
        let progress = scrubbingTo ?? model.currentTimeSeconds

        HStack(spacing: DS.Spacing.regular) {
            Button(action: togglePlayPause) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(DS.Color.accent))
            }
            .buttonStyle(.plain)
            .help(model.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("transcript.player.playPause")

            ScrubberTrack(
                progress: progress,
                duration: duration,
                onScrub: { scrubbingTo = $0 },
                onCommit: { target in
                    model.player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
                    scrubbingTo = nil
                }
            )
            .frame(height: 18)
            .accessibilityIdentifier("transcript.player.scrub")

            Text(timeLabel(current: progress, total: duration))
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 96, alignment: .trailing)

            Button { model.skipSilences.toggle() } label: {
                Image(systemName: model.skipSilences ? "forward.end.fill" : "forward.end")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.skipSilences ? DS.Color.accent : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(model.skipSilences ? DS.Color.accent.opacity(0.14) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .help(model.skipSilences ? "Skip silences (on)" : "Skip silences")

            Menu {
                ForEach(speeds, id: \.self) { s in
                    Button {
                        playbackRate = s
                        applyRate()
                    } label: {
                        if abs(s - playbackRate) < 0.001 {
                            Label(speedLabel(s), systemImage: "checkmark")
                        } else {
                            Text(speedLabel(s))
                        }
                    }
                }
            } label: {
                Text(speedLabel(playbackRate))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(DS.Color.accent.opacity(0.14))
                    )
                    .overlay(
                        Capsule().stroke(DS.Color.accent.opacity(0.35), lineWidth: 1)
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Playback speed")
            .accessibilityIdentifier("transcript.player.speed")
        }
        .padding(.horizontal, DS.Spacing.regular)
        .frame(height: 52)
        .background(DS.Color.surfaceElevated)
        .onAppear { applyRate() }
        .onChange(of: model.isPlaying) { _, playing in
            if playing { applyRate() }
        }
    }

    private func togglePlayPause() {
        guard let player = model.player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            let duration = model.transcript?.durationSeconds ?? 0
            if duration > 0, model.currentTimeSeconds >= duration - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
            applyRate()
        }
    }

    private func applyRate() {
        guard let player = model.player else { return }
        player.defaultRate = Float(playbackRate)
        if player.timeControlStatus == .playing {
            player.rate = Float(playbackRate)
        }
    }

    private func speedLabel(_ value: Double) -> String {
        if value == floor(value) {
            return "\(Int(value))×"
        }
        return "\(value)×"
    }

    private func timeLabel(current: Double, total: Double) -> String {
        "\(format(current)) / \(format(total))"
    }

    private func format(_ t: Double) -> String {
        let total = Int(max(0, t.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

struct ScrubberTrack: View {
    let progress: Double
    let duration: Double
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var isDragging: Bool = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let ratio = duration > 0 ? min(1, max(0, progress / duration)) : 0
            let knobX = width * ratio

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DS.Color.separator.opacity(0.5))
                    .frame(height: 4)
                    .frame(maxHeight: .infinity, alignment: .center)

                Capsule()
                    .fill(DS.Color.accent)
                    .frame(width: knobX, height: 4)
                    .frame(maxHeight: .infinity, alignment: .center)

                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(DS.Color.accent, lineWidth: 2))
                    .frame(width: isDragging ? 14 : 12, height: isDragging ? 14 : 12)
                    .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                    .offset(x: knobX - (isDragging ? 7 : 6))
                    .opacity(duration > 0 ? 1 : 0)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0, width > 0 else { return }
                        isDragging = true
                        let x = min(max(0, value.location.x), width)
                        onScrub(Double(x / width) * duration)
                    }
                    .onEnded { value in
                        guard duration > 0, width > 0 else { return }
                        let x = min(max(0, value.location.x), width)
                        onCommit(Double(x / width) * duration)
                        isDragging = false
                    }
            )
        }
        .disabled(duration <= 0)
    }
}
