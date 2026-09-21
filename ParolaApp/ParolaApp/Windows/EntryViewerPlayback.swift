import SwiftUI
import ParolaCore

/// The window's own transport. It drives the session's player, never the main window's.
struct EntryViewerPlaybackBar: View {
    @Bindable var session: EntryWindowSession

    @State private var scrubbingTo: Double?

    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        VStack(spacing: DS.Spacing.small) {
            ScrubberTrack(
                progress: scrubbingTo ?? session.currentTime,
                duration: session.durationSeconds,
                onScrub: { scrubbingTo = $0 },
                onCommit: { target in
                    session.scrub(to: target)
                    scrubbingTo = nil
                }
            )
            .frame(height: 18)
            .axLeaf("Slider.Scrub")

            HStack(spacing: DS.Spacing.regular) {
                Button { session.skip(by: -15) } label: {
                    Image(systemName: "gobackward.15")
                        .font(DS.Font.heading)
                        .foregroundStyle(DS.Color.primaryText)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("Back 15 seconds")
                .accessibilityLabel("Back 15 seconds")
                .axLeaf("Button.SkipBack")

                Button { session.togglePlayPause() } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .font(DS.Font.bodyStrong)
                        .foregroundStyle(DS.Color.onAccent)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(DS.Color.accent))
                }
                .buttonStyle(.plain)
                .help(session.isPlaying ? "Pause" : "Play")
                .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
                .axLeaf("Button.Play")

                Spacer(minLength: DS.Spacing.small)

                Text(verbatim: PlaybackProgressView.timeLabel(
                    current: scrubbingTo ?? session.currentTime,
                    total: session.durationSeconds
                ))
                .font(DS.Font.mono)
                .foregroundStyle(DS.Color.secondaryText)
                .axLeaf("Label.Time")

                Picker("Playback speed", selection: $session.rate) {
                    ForEach(speeds, id: \.self) { speed in
                        Text(verbatim: Self.speedLabel(speed)).tag(speed)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help("Playback speed")
                .accessibilityLabel("Playback speed")
                .axLeaf("Picker.Rate")
            }
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .chromeSurface()
    }

    static func speedLabel(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))×" : "\(value)×"
    }
}
