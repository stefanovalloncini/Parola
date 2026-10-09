import AppKit
import SwiftUI

/// A live take's newest levels as bars, newest on the right, on a shape layer that follows the take by itself, so a new sample costs no SwiftUI update.
struct LiveLevelBars: View {
    let model: AppModel
    let style: Style
    let ink: Color
    /// Off while the window is out of sight or the take is paused, so the bars hold what they show.
    let follows: Bool
    /// The stand-in's identifier, under which VoiceOver reads the level.
    let identifier: String
    /// A paused take's meter says so instead of a level.
    var paused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Under Reduce Motion the bars step this often instead of following each sample.
    nonisolated static let reduceMotionStep: TimeInterval = 0.25

    struct Style: Equatable {
        enum Alignment: Equatable {
            case center
            case bottom
        }

        let barCount: Int
        let barWidth: CGFloat
        let gap: CGFloat
        let cornerRadius: CGFloat
        /// How tall a bar stands with nothing to hear.
        let idle: CGFloat
        let height: CGFloat
        let alignment: Alignment

        var width: CGFloat { CGFloat(barCount) * (barWidth + gap) - gap }

        /// The toolbar capsule's last two seconds, standing on the box's middle.
        static let capsule = Style(barCount: 20, barWidth: 2, gap: 1, cornerRadius: 1, idle: 2, height: 16, alignment: .center)
        /// The recording pill's last three levels, standing on the box's foot.
        static let pill = Style(barCount: 3, barWidth: 3, gap: 2, cornerRadius: 1.5, idle: 3, height: 16, alignment: .bottom)

        @MainActor
        func levels(of model: AppModel) -> [Float] {
            model.takeLevels?.recent(barCount) ?? Array(repeating: 0, count: barCount)
        }

        /// One bar per level, newest on the right, top down as SwiftUI draws.
        func path(_ levels: [Float]) -> Path {
            var path = Path()
            for (index, level) in levels.enumerated() {
                let barHeight = LevelBars.height(for: level, idle: idle, max: height)
                let y = alignment == .center ? (height - barHeight) / 2 : height - barHeight
                let rect = CGRect(x: CGFloat(index) * (barWidth + gap), y: y, width: barWidth, height: barHeight)
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius), style: .continuous)
            }
            return path
        }
    }

    var body: some View {
        let step = reduceMotion ? Self.reduceMotionStep : nil
        SpokenLevelFollow(model: model, reads: .forVoiceOver(live: follows, voiceOver: model.voiceOverIsRunning, step: step)) {
            let levels = style.levels(of: model)
            let newest = Double(levels.last ?? 0)
            BarsLayer(
                levels: levels,
                style: style,
                ink: ink,
                feed: follows ? LevelFeed(model: model, style: style, step: step) : nil
            )
            .frame(width: style.width, height: style.height)
            .accessibilityRepresentation {
                Text(verbatim: AppFormat.percent(newest))
                    .accessibilityLabel("Input level")
                    .accessibilityValue(paused ? Text("Paused") : Text(verbatim: AppFormat.percent(newest)))
                    .accessibilityAddTraits(.updatesFrequently)
                    .axLeaf(identifier)
            }
        }
    }

    /// The bars on a shape layer that follows a live take on its own.
    final class BarsView: NSView {
        let bars = CAShapeLayer()
        private let content = CALayer()
        private(set) var levels: [Float] = []
        private(set) var style: Style
        private var ink: CGColor?
        private var feed: LevelFeed?
        private var following: Task<Void, Never>?

        init(style: Style) {
            self.style = style
            super.init(frame: .zero)
            layer = CALayer()
            wantsLayer = true
            // Top down, the way the style's paths run.
            content.isGeometryFlipped = true
            content.addSublayer(bars)
            layer?.addSublayer(content)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        isolated deinit {
            following?.cancel()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            withoutActions(build)
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            withoutActions(build)
        }

        func show(_ levels: [Float], style: Style, ink: CGColor) {
            guard levels != self.levels || style != self.style || ink != self.ink else { return }
            self.levels = levels
            self.style = style
            self.ink = ink
            withoutActions(build)
        }

        /// Each new sample, or under Reduce Motion four times a second, the bars take the take's levels without a SwiftUI update.
        func follow(_ feed: LevelFeed, ink: CGColor) {
            let restarts = feed != self.feed || following == nil
            self.feed = feed
            // Between restarts the levels are the loop's to move; a SwiftUI update only brings a new ink.
            show(restarts ? feed.levels() : levels, style: feed.style, ink: ink)
            guard restarts else { return }
            following?.cancel()
            let model = feed.model
            if let step = feed.step {
                following = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(step))
                        guard !Task.isCancelled, let self else { return }
                        self.showFeed()
                    }
                }
            } else {
                following = Task { [weak self] in
                    for await _ in Observations({ @MainActor in model.takeLevelTick }) {
                        guard !Task.isCancelled, let self else { return }
                        self.showFeed()
                    }
                }
            }
        }

        func stopFollowing() {
            following?.cancel()
            following = nil
            feed = nil
        }

        private func showFeed() {
            guard let feed, let ink else { return }
            show(feed.levels(), style: feed.style, ink: ink)
        }

        private func withoutActions(_ change: () -> Void) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            change()
            CATransaction.commit()
        }

        private func build() {
            content.frame = bounds
            bars.frame = content.bounds
            bars.contentsScale = window?.backingScaleFactor ?? 2
            bars.fillColor = ink
            bars.path = style.path(levels).cgPath
        }
    }
}

/// What the bars' layer reads from a live take between SwiftUI's updates.
struct LevelFeed: Equatable {
    let model: AppModel
    let style: LiveLevelBars.Style
    let step: TimeInterval?

    @MainActor
    func levels() -> [Float] {
        style.levels(of: model)
    }

    nonisolated static func == (lhs: LevelFeed, rhs: LevelFeed) -> Bool {
        lhs.model === rhs.model && lhs.style == rhs.style && lhs.step == rhs.step
    }
}

private struct BarsLayer: NSViewRepresentable {
    let levels: [Float]
    let style: LiveLevelBars.Style
    let ink: Color
    let feed: LevelFeed?

    func makeNSView(context: Context) -> LiveLevelBars.BarsView {
        LiveLevelBars.BarsView(style: style)
    }

    func updateNSView(_ view: LiveLevelBars.BarsView, context: Context) {
        let ink = ink.resolve(in: context.environment).cgColor
        if let feed {
            view.follow(feed, ink: ink)
        } else {
            view.stopFollowing()
            view.show(levels, style: style, ink: ink)
        }
    }

    static func dismantleNSView(_ view: LiveLevelBars.BarsView, coordinator: ()) {
        view.stopFollowing()
    }
}

/// How often a live meter's SwiftUI body reads the take's samples. Its layer follows them by itself, so only VoiceOver, which hears the level from SwiftUI, needs them there: as often as the bars move.
enum SpokenLevelReads: Equatable {
    case never
    case eachSample
    case every(TimeInterval)

    /// `step` is how often the bars move under Reduce Motion; nil while they follow each sample.
    static func forVoiceOver(live: Bool, voiceOver: Bool, step: TimeInterval?) -> SpokenLevelReads {
        guard live, voiceOver else { return .never }
        return step.map(SpokenLevelReads.every) ?? .eachSample
    }
}

/// Builds `content` again as `reads` says, so what it reads from the take, VoiceOver's level among it, stays current at that pace and no faster.
struct SpokenLevelFollow<Content: View>: View {
    let model: AppModel
    let reads: SpokenLevelReads
    @ViewBuilder let content: () -> Content

    var body: some View {
        TimelineView(SpokenLevelSchedule(reads: reads)) { _ in
            let _ = reads == .eachSample ? model.takeLevelTick : 0
            content()
        }
    }
}

/// Every `interval` from when it is first shown; once only for anything else, which a sample's tick or nothing moves.
private struct SpokenLevelSchedule: TimelineSchedule {
    let reads: SpokenLevelReads

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> StrideThrough<Date> {
        guard case .every(let interval) = reads else { return stride(from: startDate, through: startDate, by: 1) }
        return stride(from: startDate, through: .distantFuture, by: interval)
    }
}
