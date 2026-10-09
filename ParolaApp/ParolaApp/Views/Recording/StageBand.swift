import AppKit
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
    /// How far past the playhead a lane's name starts, in the band's empty stretch.
    nonisolated static let laneNameInset: CGFloat = 12

    /// How the band follows the take: redrawn with each sample and sliding between them, or under Reduce Motion redrawn four times a second and standing still.
    enum Cadence: Equatable {
        case glides
        case steps(every: TimeInterval)

        var step: TimeInterval? {
            if case .steps(let every) = self { every } else { nil }
        }
    }

    nonisolated static func cadence(reduceMotion: Bool) -> Cadence {
        reduceMotion ? .steps(every: LiveLevelBars.reduceMotionStep) : .glides
    }

    /// Where the bars stand between samples.
    enum Slide: Equatable {
        /// Against the playhead, never moving: under Reduce Motion.
        case still
        /// A step on from the newest sample, standing still: a take paused or out of sight.
        case held
        /// A step left over one sample's time from the newest sample's moment, then still until the next.
        case from(Date)
    }

    nonisolated static let slideKey = "slide"

    /// When a sample's slide begins in a layer's time: at the sample's moment, so an update that comes late starts part way through.
    nonisolated static func slideBegin(sampledAt: Date, now: Date, layerTime: CFTimeInterval) -> CFTimeInterval {
        layerTime - now.timeIntervalSince(sampledAt)
    }

    /// One step left over one sample's time in three frames, about thirty a second, each on the device pixel nearest the distance travelled so the bars stay crisp; until it begins they stand against the playhead.
    static func slideAnimation(beginTime: CFTimeInterval, scale: CGFloat) -> CAKeyframeAnimation {
        let frames = 3
        let slide = CAKeyframeAnimation(keyPath: "transform.translation.x")
        // Held values: a continuous slide lands between pixels, and one value per pixel makes the render server draw every pixel step.
        slide.calculationMode = .discrete
        slide.values = (0..<frames).map { -(step * CGFloat($0) / CGFloat(frames) * scale).rounded() / scale }
        slide.keyTimes = (0...frames).map { NSNumber(value: Double($0) / Double(frames)) }
        slide.duration = 1 / TakeLevelHistory.samplesPerSecond
        slide.beginTime = beginTime
        slide.fillMode = .backwards
        slide.preferredFrameRateRange = .stage
        return slide
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

    private var bars: some View {
        let cadence = Self.cadence(reduceMotion: reduceMotion)
        return SpokenLevelFollow(model: model, reads: Self.swiftUIFollowsSamples(live: drawsLive, voiceOver: model.voiceOverIsRunning, cadence: cadence)) {
            tape.drawn(cadence == .glides ? .held : .still, following: drawsLive ? feed(cadence) : nil)
        }
    }

    /// How often the band's body reads a live take's samples: only while VoiceOver reads the stand-in's level, and then as often as the bars move, since the layer view follows the take by itself.
    nonisolated static func swiftUIFollowsSamples(live: Bool, voiceOver: Bool, cadence: Cadence) -> SpokenLevelReads {
        .forVoiceOver(live: live, voiceOver: voiceOver, step: cadence.step)
    }

    private var tape: StageTape {
        Self.tape(
            levels: model.takeLevels, micLevels: model.takeMicLevels, micState: model.takeMicTrackState,
            markers: take.markers, paused: take.isPaused, macStopped: model.takeMacAudioStopped
        )
    }

    private func feed(_ cadence: Cadence) -> TapeFeed {
        TapeFeed(
            model: model, cadence: cadence, markers: take.markers, micState: model.takeMicTrackState, macStopped: model.takeMacAudioStopped
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
        stopped ? String(localized: "System audio stopped", bundle: bundle) : nil
    }

    /// The one sign for Mac audio that stopped, on its lane and on the warning line alike; the silence warning's speaker stays its own.
    nonisolated static let stoppedMacSymbol = "waveform.slash"

    /// A lane whose microphone isn't in the take draws at this strength.
    nonisolated static let offLaneStrength = 0.4

    /// The band's lanes, top to bottom: one fills it, and a meeting's two share it in equal halves, each with the band's own margins.
    nonisolated static func lanes(_ count: Int, in size: CGSize) -> [CGRect] {
        let lanes = max(1, count)
        let height = size.height / CGFloat(lanes)
        return (0..<lanes).map { CGRect(x: 0, y: CGFloat($0) * height, width: size.width, height: height) }
    }

    /// What each lane draws, top to bottom: a meeting's You lane, at `offLaneStrength` once your microphone isn't in the take, over the Mac audio; otherwise the take's levels alone.
    nonisolated static func rows(of tape: StageTape) -> [(levels: [Float], strength: Double)] {
        tape.micLevels.map { [($0, tape.micLost == nil ? 1 : offLaneStrength), (tape.levels, 1)] } ?? [(tape.levels, 1)]
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

    /// One lane's bars in the lane's own space, mirrored about its middle inside the band's 8 pt margins.
    nonisolated static func barsPath(_ levels: [Float], lane: CGSize, playheadX: CGFloat) -> Path {
        let mid = lane.height / 2
        let tallest = lane.height - 16
        var bars = Path()
        for (offset, level) in levels.reversed().enumerated() {
            let x = barX(offset: offset, playheadX: playheadX)
            if x + barWidth < 0 { break }
            let half = LevelBars.height(for: level, idle: 3, max: tallest) / 2
            let rect = CGRect(x: x, y: mid - half, width: barWidth, height: half * 2)
            bars.addRoundedRect(in: rect, cornerSize: CGSize(width: 1.5, height: 1.5), style: .continuous)
        }
        return bars
    }

    /// The flags' poles, from just under the band's top to just over its foot, each centred on its sample's bar.
    nonisolated static func polesPath(_ flags: [Int], height: CGFloat, playheadX: CGFloat) -> Path {
        var poles = Path()
        for offset in flags {
            let poleX = barX(offset: offset, playheadX: playheadX) + barWidth / 2 - 0.75
            poles.addPath(Path(roundedRect: CGRect(x: poleX, y: 3, width: 1.5, height: height - 11), cornerRadius: 0.75))
        }
        return poles
    }

    /// The flags' pennants, each pointing right from the top of its pole.
    nonisolated static func pennantsPath(_ flags: [Int], playheadX: CGFloat) -> Path {
        var pennants = Path()
        for offset in flags {
            let poleRight = barX(offset: offset, playheadX: playheadX) + barWidth / 2 + 0.75
            pennants.move(to: CGPoint(x: poleRight, y: 3))
            pennants.addLine(to: CGPoint(x: poleRight + 8, y: 6.5))
            pennants.addLine(to: CGPoint(x: poleRight, y: 10))
            pennants.closeSubpath()
        }
        return pennants
    }

    /// A lane's ink at its top, its middle and its foot: as dark over its upper half, under half as dark at its foot.
    nonisolated static func laneInk(_ ink: CGColor, strength: Double) -> [CGColor] {
        [0.55, 0.55, 0.26].map { ink.copy(alpha: ink.alpha * $0 * strength) ?? ink }
    }

    private static func drawPlayhead(in context: inout GraphicsContext, size: CGSize) {
        let playheadX = playheadX(width: size.width)
        let red = DS.Color.recordingFill
        let line = CGRect(x: playheadX - 0.75, y: 8, width: 1.5, height: size.height - 16)
        context.fill(Path(roundedRect: line, cornerRadius: 0.75), with: .color(red))
        context.fill(Path(ellipseIn: CGRect(x: playheadX - 3.5, y: 2, width: 7, height: 7)), with: .color(red))
        context.fill(Path(ellipseIn: CGRect(x: playheadX - 3.5, y: size.height - 9, width: 7, height: 7)), with: .color(red))
    }

    /// The bars and flags on layers the render server slides between samples, so the app builds the band once a sample, not once a frame.
    final class TapeView: NSView {
        /// What slides, bottom to top: the flags' poles, each lane's bars, the flags' pennants.
        let tape = CALayer()
        let poles = CAShapeLayer()
        let pennants = CAShapeLayer()
        /// Each lane's ink, cut to its bars by a shape mask.
        private(set) var lanes: [CAGradientLayer] = []
        private(set) var built: StageTape?
        private var ink: CGColor?
        private var accent: CGColor?
        private var slide: Slide?
        private var builtSize: CGSize?
        private var feed: TapeFeed?
        private var following: Task<Void, Never>?

        init() {
            super.init(frame: .zero)
            layer = CALayer()
            wantsLayer = true
            layer?.masksToBounds = true
            // Top down, the way the band's sizes and SwiftUI's paths run.
            tape.isGeometryFlipped = true
            tape.anchorPoint = .zero
            tape.addSublayer(poles)
            tape.addSublayer(pennants)
            layer?.addSublayer(tape)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        isolated deinit {
            following?.cancel()
        }

        // The band takes no clicks; one lands on whatever is under it.
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            guard newSize != builtSize else { return }
            withoutActions(build)
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            withoutActions(build)
        }

        /// The bars as of `tape`, in one transaction with the slide that starts from its sample, so the two reach the screen together.
        func show(_ tape: StageTape, slide: Slide, ink: CGColor, accent: CGColor) {
            withoutActions {
                let newBars = tape != built
                if newBars || ink != self.ink || accent != self.accent {
                    if newBars { built = tape }
                    self.ink = ink
                    self.accent = accent
                    build()
                }
                if newBars || slide != self.slide {
                    self.slide = slide
                    place(slide)
                }
            }
        }

        /// Follows a live take on its own: each new sample, or under Reduce Motion four times a second, builds the bars without a SwiftUI update.
        func follow(_ feed: TapeFeed, ink: CGColor, accent: CGColor) {
            let changed = feed != self.feed || ink != self.ink || accent != self.accent
            let cadenceChanged = feed.cadence != self.feed?.cadence || feed.model !== self.feed?.model
            self.feed = feed
            if changed || following == nil {
                showFeed(ink: ink, accent: accent)
            }
            if cadenceChanged || following == nil {
                startFollowing(feed)
            }
        }

        func stopFollowing() {
            following?.cancel()
            following = nil
            feed = nil
        }

        private func showFeed(ink: CGColor? = nil, accent: CGColor? = nil) {
            guard let feed, let ink = ink ?? self.ink, let accent = accent ?? self.accent else { return }
            show(feed.tape(), slide: feed.slide(), ink: ink, accent: accent)
        }

        private func startFollowing(_ feed: TapeFeed) {
            following?.cancel()
            let model = feed.model
            switch feed.cadence {
            case .glides:
                following = Task { [weak self] in
                    for await _ in Observations({ @MainActor in model.takeLevelTick }) {
                        guard !Task.isCancelled, let self else { return }
                        self.showFeed()
                    }
                }
            case .steps(let interval):
                following = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(interval))
                        guard !Task.isCancelled, let self else { return }
                        self.showFeed()
                    }
                }
            }
        }

        private func withoutActions(_ change: () -> Void) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            change()
            CATransaction.commit()
        }

        private func build() {
            guard let built, let ink, let accent else { return }
            let size = bounds.size
            builtSize = size
            tape.bounds = CGRect(origin: .zero, size: size)
            let playheadX = StageBand.playheadX(width: size.width)
            let rows = StageBand.rows(of: built)
            while lanes.count < rows.count {
                let lane = CAGradientLayer()
                lane.locations = [0, 0.5, 1]
                lane.startPoint = CGPoint(x: 0.5, y: 0)
                lane.endPoint = CGPoint(x: 0.5, y: 1)
                lane.mask = CAShapeLayer()
                tape.insertSublayer(lane, below: pennants)
                lanes.append(lane)
            }
            while lanes.count > rows.count {
                lanes.removeLast().removeFromSuperlayer()
            }
            for ((row, rect), lane) in zip(zip(rows, StageBand.lanes(rows.count, in: size)), lanes) {
                lane.frame = rect
                lane.colors = StageBand.laneInk(ink, strength: row.strength)
                lane.mask?.frame = lane.bounds
                (lane.mask as? CAShapeLayer)?.path = StageBand.barsPath(row.levels, lane: rect.size, playheadX: playheadX).cgPath
            }
            poles.frame = tape.bounds
            poles.path = StageBand.polesPath(built.flags, height: size.height, playheadX: playheadX).cgPath
            poles.fillColor = accent.copy(alpha: accent.alpha * 0.5)
            pennants.frame = tape.bounds
            pennants.path = StageBand.pennantsPath(built.flags, playheadX: playheadX).cgPath
            pennants.fillColor = accent
            for shape in [poles, pennants] + lanes + lanes.compactMap(\.mask) {
                shape.contentsScale = scale
            }
        }

        private var scale: CGFloat {
            window?.backingScaleFactor ?? 2
        }

        private func place(_ slide: Slide) {
            switch slide {
            case .still:
                tape.removeAnimation(forKey: StageBand.slideKey)
                tape.setAffineTransform(.identity)
            case .held:
                tape.setAffineTransform(CGAffineTransform(translationX: -StageBand.step, y: 0))
            case .from(let sampledAt):
                tape.setAffineTransform(CGAffineTransform(translationX: -StageBand.step, y: 0))
                let layerNow = tape.convertTime(CACurrentMediaTime(), from: nil)
                let begin = StageBand.slideBegin(sampledAt: sampledAt, now: Date(), layerTime: layerNow)
                tape.add(StageBand.slideAnimation(beginTime: begin, scale: scale), forKey: StageBand.slideKey)
            }
        }
    }
}

/// The tape's layer view; its colours are read from the environment on each update, so it follows a switch to dark or a new accent.
private struct TapeLayer: NSViewRepresentable {
    let tape: StageTape
    let slide: StageBand.Slide
    let feed: TapeFeed?

    func makeNSView(context: Context) -> StageBand.TapeView {
        StageBand.TapeView()
    }

    func updateNSView(_ view: StageBand.TapeView, context: Context) {
        let environment = context.environment
        let ink = DS.Color.primaryText.resolve(in: environment).cgColor
        let accent = DS.Color.accent.resolve(in: environment).cgColor
        if let feed {
            view.follow(feed, ink: ink, accent: accent)
        } else {
            view.stopFollowing()
            view.show(tape, slide: slide, ink: ink, accent: accent)
        }
    }

    static func dismantleNSView(_ view: StageBand.TapeView, coordinator: ()) {
        view.stopFollowing()
    }
}

/// What the band's layer view reads from a live take between SwiftUI's updates: the take's levels as they come in, with the rest as SwiftUI last saw it.
struct TapeFeed: Equatable {
    let model: AppModel
    let cadence: StageBand.Cadence
    let markers: [TimeInterval]
    let micState: MicTrackState?
    let macStopped: Bool

    @MainActor
    func tape() -> StageTape {
        StageBand.tape(
            levels: model.takeLevels, micLevels: model.takeMicLevels, micState: micState, markers: markers, paused: false,
            macStopped: macStopped
        )
    }

    /// Sliding from the newest sample's moment, or under Reduce Motion standing against the playhead.
    @MainActor
    func slide() -> StageBand.Slide {
        cadence == .glides ? .from(model.takeLevelTickAt) : .still
    }

    nonisolated static func == (lhs: TapeFeed, rhs: TapeFeed) -> Bool {
        lhs.model === rhs.model && lhs.cadence == rhs.cadence && lhs.markers == rhs.markers && lhs.micState == rhs.micState
            && lhs.macStopped == rhs.macStopped
    }
}

/// The band's bars and flags as of one sample. Equal until the next sample, marker, pause or change of lanes, so the bars are built only then; between samples the render server slides them.
struct StageTape: Equatable {
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

    /// The bars on their layers, sliding as `slide` says, or with a feed following a live take on their own.
    @MainActor
    func drawn(_ slide: StageBand.Slide, following feed: TapeFeed? = nil) -> some View {
        TapeLayer(tape: self, slide: slide, feed: feed)
        // A layer view carries no value; a text stand-in per lane reads its level the way the clock reads its time.
        .accessibilityRepresentation {
            if let micLevels {
                VStack {
                    level(micLevels, label: "You", lost: micLost)
                    level(levels, label: "System audio", lost: macLost)
                }
            } else {
                level(levels, label: "Input level")
            }
        }
    }

    @MainActor
    private func level(_ levels: [Float], label: LocalizedStringKey, lost: String? = nil) -> some View {
        let reading = Text(verbatim: AppFormat.percent(Double(levels.last ?? 0)))
        return reading
            .accessibilityLabel(label)
            .accessibilityValue(lost.map { Text(verbatim: $0) } ?? (paused ? Text("Paused") : reading))
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// "You" and "System audio" just past the playhead, each beside its lane; each says so once its side isn't in the take.
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
            Label(stopped, systemImage: StageBand.stoppedMacSymbol)
        } else {
            Text("System audio")
        }
    }
}
