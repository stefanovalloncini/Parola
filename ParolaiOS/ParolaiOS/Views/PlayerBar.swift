import SwiftUI

struct PlayerBar: View {
    @EnvironmentObject var model: AppModel
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : model.playback.currentTime },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(model.playback.duration, 0.01),
                onEditingChanged: { editing in
                    if editing {
                        scrubValue = model.playback.currentTime
                        isScrubbing = true
                    } else {
                        model.playback.seek(to: scrubValue)
                        isScrubbing = false
                    }
                }
            )

            HStack {
                Text(format(model.playback.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.playback.toggle()
                } label: {
                    Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                }
                Spacer()
                Text(format(model.playback.duration))
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
