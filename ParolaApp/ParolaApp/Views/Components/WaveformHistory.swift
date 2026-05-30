import SwiftUI

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

struct WaveformHistory: View {
    let level: Float
    var capacity: Int = 32
    var barWidth: CGFloat = 2
    var spacing: CGFloat = 1.5
    var maxHeight: CGFloat = 18
    var idleHeight: CGFloat = 2
    var fill: Color = .white

    @State private var history: LevelHistory

    init(
        level: Float,
        capacity: Int = 32,
        barWidth: CGFloat = 2,
        spacing: CGFloat = 1.5,
        maxHeight: CGFloat = 18,
        idleHeight: CGFloat = 2,
        fill: Color = .white
    ) {
        self.level = level
        self.capacity = capacity
        self.barWidth = barWidth
        self.spacing = spacing
        self.maxHeight = maxHeight
        self.idleHeight = idleHeight
        self.fill = fill
        _history = State(initialValue: LevelHistory(capacity: capacity))
    }

    private var contentWidth: CGFloat {
        CGFloat(capacity) * barWidth + CGFloat(max(0, capacity - 1)) * spacing
    }

    var body: some View {
        // Audio levels arrive in irregular bursts; sampling the latest level on a steady ~30fps
        // display clock makes the scroll cadence even (smooth) instead of stuttering with the input.
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            Canvas(opaque: false) { context, size in
                let samples = history.samples
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
            .onChange(of: timeline.date) { _, _ in
                history.append(level)
            }
        }
        .frame(width: contentWidth, height: maxHeight)
    }

    private func barHeight(_ value: Float) -> CGFloat {
        let shaped = pow(value, 0.6)
        let scaled = min(1, max(0, CGFloat(shaped)))
        return idleHeight + (maxHeight - idleHeight) * scaled
    }
}
