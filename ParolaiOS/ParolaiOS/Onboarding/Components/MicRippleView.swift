import SwiftUI

struct MicRippleView: View {
    var isActive: Bool = true
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive || reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            ZStack {
                if !reduceMotion {
                    Canvas { canvas, size in
                        drawRipples(canvas: canvas, size: size, time: t)
                    }
                }

                Circle()
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 110, height: 110)

                Image(systemName: "mic.fill")
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse, options: .repeating, value: pulse)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
        .onAppear { if !reduceMotion { pulse = true } }
    }

    private func drawRipples(canvas: GraphicsContext, size: CGSize, time: TimeInterval) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = min(size.width, size.height) / 2
        let cycleLength: Double = 2.4

        for i in 0..<3 {
            let phaseOffset = Double(i) * (cycleLength / 3.0)
            let progress = ((time + phaseOffset).truncatingRemainder(dividingBy: cycleLength)) / cycleLength
            let radius = CGFloat(progress) * maxRadius
            let alpha = max(1.0 - progress, 0) * 0.45
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            let path = Path(ellipseIn: rect)
            canvas.stroke(
                path,
                with: .color(Color.accentColor.opacity(alpha)),
                lineWidth: 2
            )
        }
    }
}
