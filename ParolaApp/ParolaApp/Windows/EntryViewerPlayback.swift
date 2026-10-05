import SwiftUI
import ParolaCore

/// The window's own transport. It drives the session's player, never the main window's.
struct EntryViewerPlaybackBar: View {
    @Bindable var session: EntryWindowSession

    @State private var scrubbingTo: Double?

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
                }
                .buttonStyle(GlyphButtonStyle(side: 30))
                .help("Back 15 seconds")
                .accessibilityLabel("Back 15 seconds")
                .axLeaf("Button.SkipBack")

                Button { session.togglePlayPause() } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .font(DS.Font.bodyStrong)
                        .foregroundStyle(DS.Color.onAccent)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(DS.Color.accentFill))
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
                    ForEach(PlaybackSpeed.all, id: \.self) { speed in
                        Text(verbatim: PlaybackSpeed.label(speed)).tag(speed)
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
}
