import SwiftUI

struct PlayerBar: View {
    @EnvironmentObject var model: AppModel
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        VStack(spacing: 8) {
            Slider(
                value: isScrubbing ? $scrubValue : Binding(
                    get: { model.playback.currentTime },
                    set: { _ in }
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
        let total = Int(s)
        let m = (total % 3600) / 60
        let sec = total % 60
        let h = total / 3600
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}
