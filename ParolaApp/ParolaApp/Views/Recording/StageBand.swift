import SwiftUI

/// About fifteen seconds of the take scrolling into a red playhead at 70 % of the width, its markers standing as flags; a meeting's microphone gets a lane of its own.
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
    /// How far past the playhead a lane's name starts, in the band's empty stretch.
    nonisolated static let laneNameInset: CGFloat = 12

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
        let micLane = Self.micLane(of: model)
        ZStack {
            bars
            Canvas { context, size in Self.drawPlayhead(in: &context, size: size) }
                .accessibilityHidden(true)
            if micLane.shown {
                StageLaneNames(micState: micLane.state, macStopped: model.takeMacAudioStopped)
            }
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
        Self.tape(
            levels: model.takeLevels, micLevels: model.takeMicLevels, micState: model.takeMicTrackState,
            markers: take.markers, paused: take.isPaused, macStopped: model.takeMacAudioStopped
        )
    }

    /// The band's bars as of the newest sample: the take's own levels, or for a meeting that records your microphone, its levels as "You" over the Mac audio.
    static func tape(
        levels: TakeLevelHistory?, micLevels: TakeLevelHistory?, micState: MicTrackState?, markers: [TimeInterval], paused: Bool,
        macStopped: Bool = false
    ) -> StageTape {
        let count = levels.map { min(visibleSamples, $0.sampleCount, $0.recentCapacity) } ?? 0
        let newest = (levels?.sampleCount ?? 0) - 1
        return StageTape(
            levels: levels?.recent(count) ?? [],
            micLevels: micLevels?.recent(count),
            micLost: lostMicNote(micState),
            macLost: stoppedMacNote(macStopped),
            flags: markers.compactMap { markerOffset($0, newestSample: newest) },
            newest: newest,
            paused: paused
        )
    }

    /// Whether the band has a You lane, and where your microphone stands; the observed state is read first, so a microphone that attaches always redraws the band.
    static func micLane(of model: AppModel) -> (shown: Bool, state: MicTrackState?) {
        let state = model.takeMicTrackState
        return (model.takeMicLevels != nil, state)
    }

    /// What the You lane says once your microphone isn't in the take, or no longer is; the lane greys and keeps its place until the session ends.
    nonisolated static func lostMicNote(_ state: MicTrackState?, bundle: Bundle = .main) -> String? {
        switch state {
        case .unavailable: String(localized: "Microphone not recorded", bundle: bundle)
        case .stopped: String(localized: "Microphone stopped", bundle: bundle)
        case .starting, .recording, nil: nil
        }
    }

    /// What the Mac audio lane says once its capture ended by itself while your microphone records on.
    nonisolated static func stoppedMacNote(_ stopped: Bool, bundle: Bundle = .main) -> String? {
        stopped ? String(localized: "Mac audio stopped", bundle: bundle) : nil
    }

    /// A lane whose microphone isn't in the take draws at this strength.
    nonisolated static let offLaneStrength = 0.4

    /// The band's lanes, top to bottom: one fills it, and a meeting's two share it in equal halves, each with the band's own margins.
    nonisolated static func lanes(_ count: Int, in size: CGSize) -> [CGRect] {
        let lanes = max(1, count)
        let height = size.height / CGFloat(lanes)
        return (0..<lanes).map { CGRect(x: 0, y: CGFloat($0) * height, width: size.width, height: height) }
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

    fileprivate static func drawTape(
        levels: [Float], micLevels: [Float]?, micLost: Bool, flags: [Int], in context: inout GraphicsContext, size: CGSize
    ) {
        let playheadX = playheadX(width: size.width)
        let flagColor = DS.Color.accent

        for offset in flags {
            let poleX = barX(offset: offset, playheadX: playheadX) + barWidth / 2 - 0.75
            let pole = CGRect(x: poleX, y: 3, width: 1.5, height: size.height - 11)
            context.fill(Path(roundedRect: pole, cornerRadius: 0.75), with: .color(flagColor.opacity(0.5)))
        }

        let rows: [(levels: [Float], strength: Double)] = micLevels.map { [($0, micLost ? offLaneStrength : 1), (levels, 1)] }
            ?? [(levels, 1)]
        for (row, lane) in zip(rows, lanes(rows.count, in: size)) {
            drawBars(row.levels, in: lane, strength: row.strength, playheadX: playheadX, context: &context)
        }

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

    /// One lane's bars, mirrored about its middle inside the band's 8 pt margins, inked darker at the top than the bottom.
    private static func drawBars(
        _ levels: [Float], in lane: CGRect, strength: Double, playheadX: CGFloat, context: inout GraphicsContext
    ) {
        let mid = lane.midY
        let tallest = lane.height - 16
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
                    .init(color: ink.opacity(0.55 * strength), location: 0),
                    .init(color: ink.opacity(0.55 * strength), location: 0.5),
                    .init(color: ink.opacity(0.26 * strength), location: 1),
                ]),
                startPoint: CGPoint(x: 0, y: lane.minY),
                endPoint: CGPoint(x: 0, y: lane.maxY)
            )
        )
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

/// The band's bars and flags as of one sample. Equal until the next sample, marker, pause or change of lanes, so the frames that slide it between samples never draw it again.
struct StageTape: View, Equatable {
    let levels: [Float]
    /// A meeting's microphone, drawn as the You lane over `levels`; nil for a take with one lane.
    var micLevels: [Float]?
    /// Why the You lane is grey, once your microphone isn't in the take.
    var micLost: String?
    /// What the Mac audio lane says once its capture ended by itself.
    var macLost: String?
    let flags: [Int]
    let newest: Int
    let paused: Bool

    nonisolated static func == (lhs: StageTape, rhs: StageTape) -> Bool {
        lhs.newest == rhs.newest && lhs.flags == rhs.flags && lhs.paused == rhs.paused
            && (lhs.micLevels == nil) == (rhs.micLevels == nil) && lhs.micLost == rhs.micLost && lhs.macLost == rhs.macLost
    }

    var body: some View {
        Canvas { context, size in
            StageBand.drawTape(levels: levels, micLevels: micLevels, micLost: micLost != nil, flags: flags, in: &context, size: size)
        }
        // A Canvas element carries no value; a text stand-in per lane reads its level the way the clock reads its time.
        .accessibilityRepresentation {
            if let micLevels {
                VStack {
                    level(micLevels, label: "You", lost: micLost)
                    level(levels, label: "Mac audio", lost: macLost)
                }
            } else {
                level(levels, label: "Input level")
            }
        }
    }

    private func level(_ levels: [Float], label: LocalizedStringKey, lost: String? = nil) -> some View {
        let reading = Text(verbatim: AppFormat.percent(Double(levels.last ?? 0)))
        return reading
            .accessibilityLabel(label)
            .accessibilityValue(lost.map { Text(verbatim: $0) } ?? (paused ? Text("Paused") : reading))
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// "You" and "Mac audio" just past the playhead, each beside its lane; each says so once its side isn't in the take.
private struct StageLaneNames: View {
    let micState: MicTrackState?
    let macStopped: Bool

    var body: some View {
        GeometryReader { proxy in
            let lanes = StageBand.lanes(2, in: proxy.size)
            let x = StageBand.playheadX(width: proxy.size.width) + StageBand.laneNameInset
            ZStack(alignment: .topLeading) {
                you
                    .fixedSize()
                    .frame(height: lanes[0].height)
                    .offset(x: x, y: lanes[0].minY)
                mac
                    .fixedSize()
                    .frame(height: lanes[1].height)
                    .offset(x: x, y: lanes[1].minY)
            }
        }
        .font(DS.Font.secondary)
        .foregroundStyle(DS.Color.secondaryText)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var you: some View {
        if let lost = StageBand.lostMicNote(micState) {
            Label(lost, systemImage: "mic.slash")
        } else {
            Text("You")
        }
    }

    @ViewBuilder
    private var mac: some View {
        if let stopped = StageBand.stoppedMacNote(macStopped) {
            Label(stopped, systemImage: "speaker.slash")
        } else {
            Text("Mac audio")
        }
    }
}
