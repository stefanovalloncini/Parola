import SwiftUI

struct PlayerBar: View {
    @Environment(PlaybackController.self) private var playback
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : playback.currentTime },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(playback.duration, 0.01),
                onEditingChanged: { editing in
                    if editing {
                        scrubValue = playback.currentTime
                        isScrubbing = true
                    } else {
                        playback.seek(to: scrubValue)
                        isScrubbing = false
                    }
                }
            )

            HStack {
                Text(format(playback.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    playback.toggle()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                }
                .accessibilityLabel(playback.isPlaying ? Text("Pause") : Text("Play"))
                Spacer()
                Text(format(playback.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private func format(_ s: TimeInterval) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let duration = Duration.seconds(s)
        return duration.formatted(
            .time(pattern: s >= 3600 ? .hourMinuteSecond : .minuteSecond)
        )
    }
}
