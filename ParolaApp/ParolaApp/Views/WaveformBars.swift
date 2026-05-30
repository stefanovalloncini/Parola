import SwiftUI

struct WaveformBars: View {
    let level: Float

    private static let barCount = 5
    private static let phaseOffsets: [Float] = [0.85, 1.05, 1.0, 0.95, 0.8]
    private static let idleHeight: CGFloat = 3
    private static let maxHeight: CGFloat = 18
    private static let barWidth: CGFloat = 3
    private static let spacing: CGFloat = 2

    var body: some View {
        HStack(alignment: .center, spacing: Self.spacing) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color.white)
                    .frame(width: Self.barWidth, height: barHeight(at: index))
            }
        }
        .frame(height: Self.maxHeight)
        .animation(.easeOut(duration: 0.12), value: level)
    }

    private func barHeight(at index: Int) -> CGFloat {
        if level <= 0.02 { return Self.idleHeight }
        let shaped = pow(level, 0.6)
        let offset = Self.phaseOffsets[index % Self.phaseOffsets.count]
        let scaled = min(1, max(0, CGFloat(shaped * offset)))
        return Self.idleHeight + (Self.maxHeight - Self.idleHeight) * scaled
    }
}
