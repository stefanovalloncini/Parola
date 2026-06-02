import SwiftUI

struct OnboardingTopBar: View {
    @Binding var step: OnboardingStep

    var body: some View {
        HStack {
            backButton
            Spacer(minLength: 0)
            dots
            Spacer(minLength: 0)
            skipButton
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
    }

    @ViewBuilder
    private var backButton: some View {
        if step.showsBack {
            Button {
                if let previous = step.previous { step = previous }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Back", bundle: .main))
        } else {
            Color.clear.frame(width: 44, height: 44)
        }
    }

    @ViewBuilder
    private var skipButton: some View {
        if step.showsSkip {
            Button {
                step = .done
            } label: {
                Text("Skip")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Skip"))
        } else {
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private var dots: some View {
        let steps = OnboardingStep.allCases.filter { $0.showsDots }
        let total = steps.count
        let currentIndex = steps.firstIndex(of: step) ?? 0
        return HStack(spacing: 8) {
            ForEach(steps, id: \.self) { dot in
                Capsule()
                    .fill(dot == step ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: dot == step ? 22 : 6, height: 6)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: step)
            }
        }
        .opacity(step.showsDots ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(currentIndex + 1) of \(total)"))
    }
}
