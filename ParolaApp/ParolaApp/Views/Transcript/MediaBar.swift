import SwiftUI
import AVKit

enum PlaybackSpeed {
    static let all: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    static func label(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))×" : "\(value)×"
    }
}

/// One skip step wherever a transport shows, the same the Playback menu and ⌘←/⌘→ take.
enum PlaybackSkip {
    case back, forward

    var seconds: Double { self == .back ? -5 : 5 }

    var symbol: String { self == .back ? "gobackward.5" : "goforward.5" }

    var label: String {
        self == .back ? String(localized: "Back 5 seconds") : String(localized: "Forward 5 seconds")
    }

    var help: String {
        self == .back ? String(localized: "Back 5 seconds (⌘←)") : String(localized: "Forward 5 seconds (⌘→)")
    }
}

struct PlaybackSkipButton: View {
    let skip: PlaybackSkip
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: skip.symbol)
                .font(DS.Font.heading)
                .foregroundStyle(DS.Color.primaryText)
        }
        .buttonStyle(GlyphButtonStyle(side: 30))
        .help(skip.help)
        .accessibilityLabel(skip.label)
    }
}

struct MediaBar: View {
    @Environment(AppModel.self) private var model
    @AppStorage("playbackRate", store: DefaultsStore.current) private var playbackRate: Double = 1.0
    @State private var scrubbingTo: Double?

    var body: some View {
        VStack(spacing: DS.Spacing.small) {
            PlaybackProgressView(scrubbingTo: $scrubbingTo)
            HStack(spacing: DS.Spacing.regular) {
                skipSilencesButton
                    .frame(maxWidth: .infinity, alignment: .leading)
                transport
                readout
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .chromeSurface()
        .onAppear { applyRate() }
        .onChange(of: model.isPlaying) { _, playing in
            if playing { applyRate() }
        }
    }

    private var transport: some View {
        HStack(spacing: DS.Spacing.regular) {
            PlaybackSkipButton(skip: .back) { model.skip(by: PlaybackSkip.back.seconds) }
                .accessibilityIdentifier("transcript.player.skipBack")
                .axLeaf("MediaBar.Button.SkipBack")

            Button(action: togglePlayPause) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.onAccent)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(DS.Color.accentFill))
            }
            .buttonStyle(.plain)
            .help(model.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("transcript.player.playPause")
            .axLeaf("MediaBar.Button.PlayPause")

            PlaybackSkipButton(skip: .forward) { model.skip(by: PlaybackSkip.forward.seconds) }
                .accessibilityIdentifier("transcript.player.skipForward")
                .axLeaf("MediaBar.Button.SkipForward")
        }
    }

    private var skipSilencesButton: some View {
        Button { model.skipSilences.toggle() } label: {
            Image(systemName: model.skipSilences ? "forward.end.fill" : "forward.end")
                .font(DS.Font.bodyStrong)
                .foregroundStyle(model.skipSilences ? DS.Color.accent : .secondary)
                .padding(.horizontal, DS.Spacing.small)
                .padding(.vertical, DS.Spacing.tight)
        }
        .buttonStyle(SkipSilencesButtonStyle(isOn: model.skipSilences))
        .help(model.skipSilences ? "Skip silences (on)" : "Skip silences")
        .accessibilityLabel("Skip silences")
        .accessibilityValue(model.skipSilences ? "On" : "Off")
        .axLeaf("MediaBar.Button.SkipSilences")
    }

    private var readout: some View {
        HStack(spacing: DS.Spacing.small) {
            PlaybackTimeLabel(scrubbingTo: scrubbingTo)
            speedMenu
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach(PlaybackSpeed.all, id: \.self) { s in
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
            HStack(spacing: 3) {
                Text(speedLabel(playbackRate))
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(DS.Font.caption)
            }
        }
        .menuStyle(.button)
        .buttonStyle(SpeedPillStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback speed")
        .accessibilityLabel("Playback speed")
        .accessibilityValue(speedLabel(playbackRate))
        .accessibilityIdentifier("transcript.player.speed")
        .axLeaf("MediaBar.Menu.Speed")
    }

    private func togglePlayPause() {
        let wasPlaying = model.player?.timeControlStatus == .playing
        model.togglePlayPause()
        if !wasPlaying {
            applyRate()
        }
    }

    private func applyRate() {
        model.applyPlaybackRate(playbackRate)
    }

    private func speedLabel(_ value: Double) -> String {
        PlaybackSpeed.label(value)
    }
}

/// The rate's capsule: `.borderlessButton` would drop it and leave the rate looking like plain text.
private struct SpeedPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.mono.weight(.semibold))
            .foregroundStyle(DS.Color.accentInk)
            .padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.tight)
            .background(Capsule().fill(DS.Color.accentWash))
            .overlay(Capsule().strokeBorder(DS.Color.accent.opacity(0.35), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Capsule())
    }
}

/// The capsule twin of `GlyphButtonStyle`: same hover wash and press fill, shaped to match the toggle's pill.
private struct SkipSilencesButtonStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, isOn: isOn)
    }

    private struct Chrome: View {
        let configuration: Configuration
        let isOn: Bool

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let appearance = GlyphButtonAppearance(
                hovered: hovering,
                pressed: configuration.isPressed,
                enabled: isEnabled,
                selectedFill: isOn ? DS.Color.accent.opacity(0.14) : nil
            )
            configuration.label
                .background(Capsule().fill(appearance.fill))
                .opacity(appearance.opacity)
                .contentShape(Capsule())
                .rowStateAnimation(hovering)
                .onHover { hovering = $0 }
        }
    }
}

struct PlaybackProgressView: View {
    @Environment(AppModel.self) private var model
    @Binding var scrubbingTo: Double?

    var body: some View {
        let duration = model.transcript?.durationSeconds ?? 0
        ScrubberTrack(
            progress: scrubbingTo ?? model.currentTimeSeconds,
            duration: duration,
            onScrub: { scrubbingTo = $0 },
            onCommit: { target in
                model.seekPlayer(to: target, precise: false)
                scrubbingTo = nil
            }
        )
        .frame(height: 18)
        .accessibilityIdentifier("transcript.player.scrub")
    }

    static func timeLabel(current: Double, total: Double) -> String {
        "\(format(current)) / \(format(total))"
    }

    static func format(_ t: Double) -> String {
        let total = Int(max(0, t.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

/// The playhead's time, then the duration on its own, which a landing take's clock shrinks into.
struct PlaybackTimeLabel: View {
    @Environment(AppModel.self) private var model
    let scrubbingTo: Double?

    var body: some View {
        let current = scrubbingTo ?? model.currentTimeSeconds
        let total = model.transcript?.durationSeconds ?? 0
        HStack(spacing: 0) {
            Text(verbatim: PlaybackProgressView.format(current) + " / ")
            Text(verbatim: PlaybackProgressView.format(total))
                .stageLandingDestination(.time)
        }
        .font(DS.Font.mono)
        .foregroundStyle(DS.Color.secondaryText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: PlaybackProgressView.timeLabel(current: current, total: total)))
    }
}

struct ScrubberTrack: View {
    let progress: Double
    let duration: Double
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var isDragging: Bool = false

    static func stepped(_ progress: Double, by delta: Double, duration: Double) -> Double {
        min(max(0, progress + delta), duration)
    }

    static func spokenPosition(progress: Double, duration: Double) -> String {
        String(localized: "\(PlaybackProgressView.format(progress)) of \(PlaybackProgressView.format(duration))")
    }

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
        .accessibilityElement()
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text(verbatim: Self.spokenPosition(progress: progress, duration: duration)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: _ = step(by: PlaybackSkip.forward.seconds)
            case .decrement: _ = step(by: PlaybackSkip.back.seconds)
            @unknown default: break
            }
        }
        .focusable(duration > 0, interactions: .activate)
        .onKeyPress(.leftArrow) { step(by: PlaybackSkip.back.seconds) }
        .onKeyPress(.rightArrow) { step(by: PlaybackSkip.forward.seconds) }
    }

    private func step(by delta: Double) -> KeyPress.Result {
        guard duration > 0 else { return .ignored }
        onCommit(Self.stepped(progress, by: delta, duration: duration))
        return .handled
    }
}
