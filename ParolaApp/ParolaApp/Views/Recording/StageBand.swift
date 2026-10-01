import SwiftUI

/// About fifteen seconds of the take scrolling into a red playhead at 70 % of the width, its markers standing as flags.
struct StageBand: View {
    let take: RecordingSession
    /// Off while the Stage is out of sight, so the band stops drawing; the take's levels keep filling regardless.
    let isOnScreen: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static let height: CGFloat = 140
    nonisolated static let barWidth: CGFloat = 3
    nonisolated static let gap: CGFloat = 2
    nonisolated static let step: CGFloat = barWidth + gap
    nonisolated static let playhead: CGFloat = 0.7
    nonisolated static let visibleSamples = 480
    /// The bars slide at most this often; between samples nothing but their offset changes.
    nonisolated static let glideFrame: TimeInterval = 1.0 / 30

    /// How the band follows the take: redrawn with each sample and sliding between them, or under Reduce Motion redrawn four times a second and standing still.
    enum Cadence: Equatable {
        case glides
        case steps(every: TimeInterval)
    }

    nonisolated static func cadence(reduceMotion: Bool) -> Cadence {
        reduceMotion ? .steps(every: 0.25) : .glides
    }

    /// How far the bars have slid left since the newest sample came in: one step over one sample's time, then still until the next.
    nonisolated static func glide(sinceTick elapsed: TimeInterval) -> CGFloat {
        step * CGFloat(min(1, max(0, elapsed * TakeLevelHistory.samplesPerSecond)))
    }

    private var drawsLive: Bool { isOnScreen && take.state == .recording }

    /// A failed take's band stays where it stopped, drained of colour and set back behind the banner.
    nonisolated static func greys(_ state: RecordingSession.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    var body: some View {
        ZStack {
            bars
            Canvas { context, size in Self.drawPlayhead(in: &context, size: size) }
                .accessibilityHidden(true)
        }
        .saturation(take.isPaused || Self.greys(take.state) ? 0 : 1)
        .opacity(Self.greys(take.state) ? 0.45 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: take.isPaused)
        .mask {
            LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    @ViewBuilder
    private var bars: some View {
        switch Self.cadence(reduceMotion: reduceMotion) {
        case .steps(let interval):
            TimelineView(.animation(minimumInterval: interval, paused: !drawsLive)) { _ in tape.equatable() }
        case .glides:
            let _ = drawsLive ? model.takeLevelTick : 0
            let tape = tape
            // Read with the bars, not in the timeline, which can run before the bars catch up with a new sample.
            let sampledAt = model.takeLevelTickAt
            TimelineView(.animation(minimumInterval: Self.glideFrame, paused: !drawsLive)) { context in
                tape.equatable()
                    // One image, or the renderer can show new bars at the old offset for a frame, a jolt of a step or more.
                    .drawingGroup()
                    .offset(x: -Self.glide(sinceTick: context.date.timeIntervalSince(sampledAt)))
            }
        }
    }

    private var tape: StageTape {
        let history = model.takeLevels
        let count = history.map { min(Self.visibleSamples, $0.sampleCount, $0.recentCapacity) } ?? 0
        let newest = (history?.sampleCount ?? 0) - 1
        return StageTape(
            levels: history?.recent(count) ?? [],
            flags: take.markers.compactMap { Self.markerOffset($0, newestSample: newest) },
            newest: newest,
            paused: take.isPaused
        )
    }

    nonisolated static func playheadX(width: CGFloat) -> CGFloat {
        (width * playhead).rounded()
    }

    /// The left edge of the bar `offset` samples back from the newest one, which sits against the playhead.
    nonisolated static func barX(offset: Int, playheadX: CGFloat) -> CGFloat {
        playheadX - gap - barWidth - CGFloat(offset) * step
    }

    /// How many samples back from the newest a marker at `time` into the take sits; nil once it has left the band.
    nonisolated static func markerOffset(_ time: TimeInterval, newestSample: Int) -> Int? {
        let sample = Int((time * TakeLevelHistory.samplesPerSecond).rounded(.down))
        let offset = max(0, newestSample - sample)
        return offset < visibleSamples ? offset : nil
    }

    fileprivate static func drawTape(levels: [Float], flags: [Int], in context: inout GraphicsContext, size: CGSize) {
        let playheadX = playheadX(width: size.width)
        let mid = size.height / 2
        let tallest = size.height - 16
        let flagColor = DS.Color.accent

        for offset in flags {
            let poleX = barX(offset: offset, playheadX: playheadX) + barWidth / 2 - 0.75
            let pole = CGRect(x: poleX, y: 3, width: 1.5, height: size.height - 11)
            context.fill(Path(roundedRect: pole, cornerRadius: 0.75), with: .color(flagColor.opacity(0.5)))
        }

        var bars = Path()
        for (offset, level) in levels.reversed().enumerated() {
            let x = barX(offset: offset, playheadX: playheadX)
            if x + barWidth < 0 { break }
            let half = LevelBars.height(for: level, idle: 3, max: tallest) / 2
            let rect = CGRect(x: x, y: mid - half, width: barWidth, height: half * 2)
            bars.addRoundedRect(in: rect, cornerSize: CGSize(width: 1.5, height: 1.5), style: .continuous)
        }
        let ink = DS.Color.primaryText
        context.fill(
            bars,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: ink.opacity(0.55), location: 0),
                    .init(color: ink.opacity(0.55), location: 0.5),
                    .init(color: ink.opacity(0.26), location: 1),
                ]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )

        for offset in flags {
            let poleRight = barX(offset: offset, playheadX: playheadX) + barWidth / 2 + 0.75
            var pennant = Path()
            pennant.move(to: CGPoint(x: poleRight, y: 3))
            pennant.addLine(to: CGPoint(x: poleRight + 8, y: 6.5))
            pennant.addLine(to: CGPoint(x: poleRight, y: 10))
            pennant.closeSubpath()
            context.fill(pennant, with: .color(flagColor))
        }
    }

    private static func drawPlayhead(in context: inout GraphicsContext, size: CGSize) {
        let playheadX = playheadX(width: size.width)
        let red = DS.Color.recordingFill
        let line = CGRect(x: playheadX - 0.75, y: 8, width: 1.5, height: size.height - 16)
        context.fill(Path(roundedRect: line, cornerRadius: 0.75), with: .color(red))
        context.fill(Path(ellipseIn: CGRect(x: playheadX - 3.5, y: 2, width: 7, height: 7)), with: .color(red))
        context.fill(Path(ellipseIn: CGRect(x: playheadX - 3.5, y: size.height - 9, width: 7, height: 7)), with: .color(red))
    }
}

/// The band's bars and flags as of one sample. Equal until the next sample, marker or pause, so the frames that slide it between samples never draw it again.
struct StageTape: View, Equatable {
    let levels: [Float]
    let flags: [Int]
    let newest: Int
    let paused: Bool

    nonisolated static func == (lhs: StageTape, rhs: StageTape) -> Bool {
        lhs.newest == rhs.newest && lhs.flags == rhs.flags && lhs.paused == rhs.paused
    }

    var body: some View {
        Canvas { context, size in
            StageBand.drawTape(levels: levels, flags: flags, in: &context, size: size)
        }
        // A Canvas element carries no value; a text stand-in reads the level the way the clock reads its time.
        .accessibilityRepresentation {
            Text(verbatim: AppFormat.percent(Double(levels.last ?? 0)))
                .accessibilityLabel("Input level")
                .accessibilityValue(paused ? Text("Paused") : Text(verbatim: AppFormat.percent(Double(levels.last ?? 0))))
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
