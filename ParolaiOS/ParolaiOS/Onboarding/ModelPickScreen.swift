import SwiftUI
import ParolaCore

struct ModelPickScreen: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    @EnvironmentObject private var model: AppModel

    private let options: [ModelChoice] = [
        ModelChoice(name: "openai_whisper-tiny", label: "Tiny", sizeMB: 75,
                    descriptionLabelKey: "onboarding.model.tiny.body",
                    speed: 3, accuracy: 1),
        ModelChoice(name: "openai_whisper-base", label: "Base", sizeMB: 145,
                    descriptionLabelKey: "onboarding.model.base.body",
                    speed: 2, accuracy: 2),
        ModelChoice(name: "openai_whisper-small", label: "Small", sizeMB: 480,
                    descriptionLabelKey: "onboarding.model.small.body",
                    speed: 1, accuracy: 3)
    ]

    var body: some View {
        OnboardingScreen(
            headline: "onboarding.model.headline",
            body: ["onboarding.model.subhead"],
            primaryTitle: "onboarding.cta.continue",
            primaryAction: {
                startDownload(for: model.settings.modelName)
                onContinue()
            },
            hero: { modelCards },
            footer: {
                Text("onboarding.model.footer")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        )
    }

    private var modelCards: some View {
        VStack(spacing: 12) {
            ForEach(Array(options.enumerated()), id: \.element.name) { index, option in
                ModelOptionCard(
                    choice: option,
                    isSelected: model.settings.modelName == option.name,
                    onTap: { model.settings.modelName = option.name }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
                .animation(
                    .spring(response: 0.5, dampingFraction: 0.85).delay(Double(index) * 0.08),
                    value: model.settings.modelName
                )
            }
        }
        .padding(.horizontal, 4)
    }

    private func startDownload(for variant: String) {
        guard !ModelStore.shared.isInstalled(variant) else { return }
        Task.detached(priority: .utility) {
            _ = try? await ModelStore.shared.download(variant: variant)
        }
    }
}

struct ModelChoice: Hashable, Sendable {
    let name: String
    let label: String
    let sizeMB: Int
    let descriptionLabelKey: String
    let speed: Int
    let accuracy: Int

    var description: LocalizedStringKey { LocalizedStringKey(descriptionLabelKey) }
}
