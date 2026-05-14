import SwiftUI

struct LanguagePickScreen: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    @EnvironmentObject private var model: AppModel
    @State private var showingFullList = false

    var body: some View {
        OnboardingScreen(
            headline: "onboarding.language.headline",
            body: ["onboarding.language.subhead"],
            primaryTitle: "onboarding.cta.continue",
            primaryAction: onContinue,
            hero: { RotatingGlobeView() },
            footer: {
                Button {
                    showingFullList = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "globe")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                        Text(LanguageCatalog.label(for: model.settings.language))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        )
        .sheet(isPresented: $showingFullList) {
            NavigationStack {
                LanguagePicker(selection: $model.settings.language, compact: false)
                    .navigationTitle(Text("language.choose"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: { showingFullList = false }) {
                                Text("Done")
                            }
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
}
