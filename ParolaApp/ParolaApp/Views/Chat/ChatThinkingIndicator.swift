import SwiftUI

struct ChatThinkingIndicator: View {
    var isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: !isActive)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(DS.Color.secondaryText)
                        .frame(width: 6, height: 6)
                        .opacity(dotOpacity(time: t, index: i))
                }
            }
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.vertical, DS.Spacing.small)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    .fill(DS.Color.surfaceElevated)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, DS.Spacing.hair)
        }
    }

    private func dotOpacity(time: TimeInterval, index: Int) -> Double {
        let cycle = 1.2
        let phase = (time / cycle).truncatingRemainder(dividingBy: 1)
        let offset = Double(index) * 0.15
        let local = (phase - offset + 1).truncatingRemainder(dividingBy: 1)
        let wave = sin(local * .pi)
        return 0.3 + max(0, wave) * 0.7
    }
}
