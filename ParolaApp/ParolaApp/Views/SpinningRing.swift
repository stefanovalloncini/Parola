import SwiftUI

struct SpinningRing: View {
    @State private var rotate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(rotate ? 360 : 0))
            .animation(
                reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false),
                value: rotate
            )
            .onAppear { if !reduceMotion { rotate = true } }
    }
}
