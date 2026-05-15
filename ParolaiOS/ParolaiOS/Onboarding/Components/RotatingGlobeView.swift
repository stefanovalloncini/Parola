import SwiftUI

struct RotatingGlobeView: View {
    var isActive: Bool = true
    @State private var animateColor = false

    private let greetings: [Greeting] = [
        Greeting(text: "ciao", offsetX: -110, offsetY: -60, phase: 0),
        Greeting(text: "hello", offsetX: 110, offsetY: -40, phase: 1.3),
        Greeting(text: "hola", offsetX: -90, offsetY: 80, phase: 2.6),
        Greeting(text: "salut", offsetX: 90, offsetY: 90, phase: 3.9)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !isActive)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            content(time: t)
        }
        .onAppear { animateColor = true }
    }

    @ViewBuilder
    private func content(time: TimeInterval) -> some View {
        ZStack {
            ForEach(greetings) { greeting in
                greetingBubble(greeting, time: time)
            }

            Image(systemName: "globe")
                .font(.system(size: 110, weight: .light))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating, value: animateColor)
                .shadow(color: Color.accentColor.opacity(0.2), radius: 18, x: 0, y: 6)
        }
    }

    private func greetingBubble(_ greeting: Greeting, time: TimeInterval) -> some View {
        let floatY = CGFloat(sin(time * 0.9 + greeting.phase) * 6)
        return Text(greeting.text)
            .font(.body.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Color(.tertiarySystemBackground))
            )
            .overlay(
                Capsule().stroke(Color.accentColor.opacity(0.18), lineWidth: 0.5)
            )
            .offset(x: greeting.offsetX, y: greeting.offsetY + floatY)
    }
}

private struct Greeting: Identifiable {
    let id = UUID()
    let text: String
    let offsetX: CGFloat
    let offsetY: CGFloat
    let phase: Double
}
