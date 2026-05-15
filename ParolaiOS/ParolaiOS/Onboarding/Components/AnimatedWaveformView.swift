import SwiftUI

struct AnimatedWaveformView: View {
    var isActive: Bool = true
    private let barCount = 28
    @State private var seeds: [Double] = (0..<28).map { _ in .random(in: 0...1) }

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                Canvas { canvas, size in
                    draw(into: canvas, size: size, time: t)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    private func draw(into canvas: GraphicsContext, size: CGSize, time: TimeInterval) {
        let width = size.width
        let height = size.height
        let spacing: CGFloat = 4
        let totalSpacing = spacing * CGFloat(barCount - 1)
        let barWidth = max((width - totalSpacing) / CGFloat(barCount), 2)
        let midY = height / 2
        let maxAmplitude = height * 0.42

        let accent = Color.accentColor
        let secondary = Color.accentColor.opacity(0.5)

        for index in 0..<barCount {
            let phase = time * 1.6 + seeds[index] * .pi * 2
            let secondary_phase = time * 2.3 + Double(index) * 0.4
            let amplitude = (sin(phase) * 0.6 + sin(secondary_phase) * 0.35) * 0.5 + 0.5
            let height = max(amplitude * Double(maxAmplitude), 6)

            let x = CGFloat(index) * (barWidth + spacing)
            let rect = CGRect(
                x: x,
                y: midY - CGFloat(height) / 2,
                width: barWidth,
                height: CGFloat(height)
            )

            let isLeading = index % 4 == 0
            let color = isLeading ? accent : secondary
            let shape = Capsule().path(in: rect)
            canvas.fill(shape, with: .color(color))
        }
    }
}
