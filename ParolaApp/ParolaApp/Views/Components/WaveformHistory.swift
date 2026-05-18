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

    @State private var history = LevelHistory(capacity: 32)

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<history.samples.count, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(fill)
                    .frame(width: barWidth, height: barHeight(history.samples[index]))
            }
        }
        .frame(height: maxHeight)
        .onAppear { history = LevelHistory(capacity: capacity) }
        .onChange(of: level) { _, newValue in
            history.append(newValue)
        }
    }

    private func barHeight(_ value: Float) -> CGFloat {
        let shaped = pow(value, 0.6)
        let scaled = min(1, max(0, CGFloat(shaped)))
        return idleHeight + (maxHeight - idleHeight) * scaled
    }
}
