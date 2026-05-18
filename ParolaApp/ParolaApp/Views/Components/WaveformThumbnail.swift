import SwiftUI

struct WaveformThumbnail: View {
    let samples: [Float]
    var progress: Double = 0
    var color: Color = .accentColor
    var background: Color = .secondary.opacity(0.18)

    var body: some View {
        GeometryReader { proxy in
            let count = samples.count
            let width = proxy.size.width
            let height = proxy.size.height
            let spacing: CGFloat = 1
            let barWidth = max(1, (width - spacing * CGFloat(max(0, count - 1))) / CGFloat(max(1, count)))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    let amplitude = CGFloat(min(1, max(0, samples[index])))
                    let h = max(1, amplitude * height)
                    let played = Double(index + 1) / Double(count) <= progress
                    Capsule(style: .continuous)
                        .fill(played ? color : background)
                        .frame(width: barWidth, height: h)
                }
            }
            .frame(width: width, height: height, alignment: .center)
        }
    }
}
