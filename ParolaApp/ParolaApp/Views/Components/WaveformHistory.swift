import SwiftUI
import ParolaCore

struct LevelHistory: Equatable, Sendable {
    private(set) var samples: [Float]

    init(capacity: Int = 32) {
        let slots = max(1, capacity)
        self.samples = Array(repeating: 0, count: slots)
    }

    mutating func append(_ value: Float) {
        let clamped = min(1, max(0, value))
        samples.removeFirst()
        samples.append(clamped)
    }
}

/// Ticks at `interval` while the capture hears sound; a second after it stops, polls four times a second for its return.
struct LevelMeterSchedule: TimelineSchedule {
    static let interval: TimeInterval = 1.0 / 30.0
    static let restingPoll: TimeInterval = 0.25
    static let restAfter: Duration = .seconds(1)

    let meter: LevelMeter

    static func isResting(lastSound: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Bool {
        guard let lastSound else { return true }
        return lastSound.duration(to: now) >= restAfter
    }

    /// The step to the next frame, read from the meter as each one is asked for.
    static func step(lastSound: ContinuousClock.Instant?, now: ContinuousClock.Instant, mode: Mode) -> TimeInterval {
        guard mode == .normal else { return 1 }
        return isResting(lastSound: lastSound, now: now) ? restingPoll : interval
    }

    func entries(from startDate: Date, mode: Mode) -> Entries {
        Entries(meter: meter, mode: mode, date: startDate)
    }

    struct Entries: Sequence, IteratorProtocol {
        let meter: LevelMeter
        let mode: Mode
        var date: Date

        /// Frames stay on the grid they started on; only one that fell behind restarts from now.
        mutating func next() -> Date? {
            defer {
                let step = LevelMeterSchedule.step(lastSound: meter.lastSound, now: .now, mode: mode)
                let now = Date()
                date = date.addingTimeInterval(step)
                if date < now { date = now.addingTimeInterval(step) }
            }
            return date
        }
    }
}

/// The bars a history meter draws. A reference, not `@State`: each frame appends without invalidating the view.
final class LevelTrace {
    private(set) var history: LevelHistory
    private var sampledAt: Date?

    init(capacity: Int) {
        history = LevelHistory(capacity: capacity)
    }

    /// One sample per frame date, however often SwiftUI evaluates that frame. A resting poll adds none, so the bars
    /// hold still in silence instead of crawling at the poll's pace.
    func samples(at date: Date, reading meter: LevelMeter, now: ContinuousClock.Instant = .now) -> [Float] {
        guard date != sampledAt else { return history.samples }
        sampledAt = date
        // Read even at rest, so the first bar after the silence is not the peak from before it.
        let peak = meter.takePeak()
        if !LevelMeterSchedule.isResting(lastSound: meter.lastSound, now: now) { history.append(peak) }
        return history.samples
    }
}

struct WaveformHistory: View {
    private let meter: LevelMeter?
    var capacity: Int = 32
    var barWidth: CGFloat = 2
    var spacing: CGFloat = 1.5
    var maxHeight: CGFloat = 18
    var idleHeight: CGFloat = 2
    var fill: Color = .white

    /// A ready window of levels. When it is there the view draws it as-is instead of reading a meter.
    private let envelope: [Float]?

    /// A history its owner keeps, so the bars outlive this view; without one the view keeps its own.
    private let heldTrace: LevelTrace?
    @State private var ownTrace: LevelTrace

    private var trace: LevelTrace { heldTrace ?? ownTrace }

    init(
        meter: LevelMeter?,
        trace: LevelTrace? = nil,
        capacity: Int = 32,
        barWidth: CGFloat = 2,
        spacing: CGFloat = 1.5,
        maxHeight: CGFloat = 18,
        idleHeight: CGFloat = 2,
        fill: Color = .white
    ) {
        self.meter = meter
        self.capacity = capacity
        self.barWidth = barWidth
        self.spacing = spacing
        self.maxHeight = maxHeight
        self.idleHeight = idleHeight
        self.fill = fill
        self.envelope = nil
        self.heldTrace = trace
        _ownTrace = State(initialValue: LevelTrace(capacity: capacity))
    }

    init(
        samples: [Float],
        barWidth: CGFloat = 2,
        spacing: CGFloat = 1.5,
        maxHeight: CGFloat = 18,
        idleHeight: CGFloat = 2,
        fill: Color = .white
    ) {
        self.meter = nil
        self.capacity = samples.count
        self.barWidth = barWidth
        self.spacing = spacing
        self.maxHeight = maxHeight
        self.idleHeight = idleHeight
        self.fill = fill
        self.envelope = samples
        self.heldTrace = nil
        // The envelope draws itself; the trace behind a meter is never sampled on this path.
        _ownTrace = State(initialValue: LevelTrace(capacity: 1))
    }

    private var contentWidth: CGFloat {
        CGFloat(capacity) * barWidth + CGFloat(max(0, capacity - 1)) * spacing
    }

    var body: some View {
        Group {
            if let envelope {
                bars(envelope)
            } else if let meter {
                // Sampling on a steady display clock keeps the scroll even while buffers arrive in bursts.
                TimelineView(LevelMeterSchedule(meter: meter)) { timeline in
                    bars(trace.samples(at: timeline.date, reading: meter))
                }
            } else {
                bars(trace.history.samples)
            }
        }
        .frame(width: contentWidth, height: maxHeight)
    }

    private func bars(_ samples: [Float]) -> some View {
        Canvas(opaque: false) { context, size in
            for (index, sample) in samples.enumerated() {
                let height = barHeight(sample)
                let x = CGFloat(index) * (barWidth + spacing)
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2, style: .continuous),
                    with: .color(fill)
                )
            }
        }
    }

    private func barHeight(_ value: Float) -> CGFloat {
        let shaped = pow(value, 0.6)
        let scaled = min(1, max(0, CGFloat(shaped)))
        return idleHeight + (maxHeight - idleHeight) * scaled
    }
}

/// Draws whatever a meter reads now, on the same resting clock as the history.
struct LevelMeterReading<Content: View>: View {
    let meter: LevelMeter?
    @ViewBuilder let content: (Float) -> Content

    var body: some View {
        if let meter {
            TimelineView(LevelMeterSchedule(meter: meter)) { _ in
                content(meter.level)
            }
        } else {
            content(0)
        }
    }
}
