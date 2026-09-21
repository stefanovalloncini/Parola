import SwiftUI

struct IntroductionBottomBar: View {
    enum SecondaryAction {
        case openFile
    }

    @Environment(AppModel.self) private var model

    static func secondaryAction(for step: IntroductionStep) -> SecondaryAction? {
        step == .ready ? .openFile : nil
    }

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
            if let secondary = Self.secondaryAction(for: introduction.step) {
                secondaryButton(secondary)
            }
            Button(primaryTitle(introduction.step)) {
                if introduction.isLastStep { introduction.finish() } else { model.advanceIntroduction() }
            }
            .buttonStyle(DSPillButtonStyle(kind: .primary, size: .regular))
            .keyboardShortcut(.defaultAction)
            .axLeaf("Introduction.Button.\(primaryRole(introduction.step))")
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func secondaryButton(_ action: SecondaryAction) -> some View {
        switch action {
        case .openFile:
            Button("Open a File…") {
                model.introduction.finish()
                model.presentOpenPanel()
            }
            .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .regular))
            .axLeaf("Introduction.Button.OpenFile")
        }
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
