import SwiftUI

struct IntroductionBottomBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let introduction = model.introduction
        return HStack(spacing: DS.Spacing.small) {
            IntroductionStepDots(index: introduction.stepIndex, total: introduction.steps.count)
            Spacer(minLength: DS.Spacing.large)
            if introduction.canGoBack {
                Button("Back") { introduction.back() }
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf("Introduction.Button.Back")
            }
            if !introduction.isLastStep {
                Button("Skip") { introduction.skip() }
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf("Introduction.Button.Skip")
            }
            Button(primaryTitle(introduction.step)) {
                if introduction.isLastStep { introduction.finish() } else { introduction.advance() }
            }
            .buttonStyle(DSPillButtonStyle(kind: .primary, size: .regular))
            .keyboardShortcut(.defaultAction)
            .axLeaf("Introduction.Button.\(primaryRole(introduction.step))")
        }
        .frame(maxWidth: .infinity)
    }

    private func primaryTitle(_ step: IntroductionStep) -> LocalizedStringKey {
        switch step {
        case .hello: "Begin"
        case .ready: "Open Parola"
        case .transcribe, .features, .engine: "Continue"
        }
    }

    private func primaryRole(_ step: IntroductionStep) -> String {
        switch step {
        case .hello: "Begin"
        case .ready: "Finish"
        case .transcribe, .features, .engine: "Continue"
        }
    }
}

struct IntroductionStepDots: View {
    let index: Int
    let total: Int

    var body: some View {
        HStack(spacing: DS.Spacing.snug) {
            ForEach(0..<total, id: \.self) { position in
                Capsule(style: .continuous)
                    .fill(position == index ? DS.Color.accent : DS.Color.secondaryText.opacity(0.25))
                    .frame(width: position == index ? 22 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(index + 1) of \(total)"))
    }
}
