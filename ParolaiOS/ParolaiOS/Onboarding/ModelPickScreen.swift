import SwiftUI
import ParolaCore

struct ModelPickScreen: View {
    let onContinue: () -> Void

    @Environment(AppModel.self) private var model

    private let groups: [(ModelCategory, [ModelVariant])] = ModelCatalog.groupedForPicker()

    var body: some View {
        OnboardingScreen(
            headline: "onboarding.model.headline",
            body: ["onboarding.model.subhead"],
            primaryTitle: "onboarding.cta.continue",
            primaryAction: {
                applyDefaultLanguageIfNeeded(for: model.settings.modelName)
                startDownload(for: model.settings.modelName)
                onContinue()
            },
            hero: { modelGroups },
            footer: {
                Text("onboarding.model.footer")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        )
    }

    private var modelGroups: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 18) {
                ForEach(groups, id: \.0) { category, variants in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(category.displayName.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        VStack(spacing: 8) {
                            ForEach(variants, id: \.id) { variant in
                                ModelVariantRow(
                                    variant: variant,
                                    isSelected: model.settings.modelName == variant.id
                                ) {
                                    model.settings.modelName = variant.id
                                    applyDefaultLanguageIfNeeded(for: variant.id)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity)
    }

    private func applyDefaultLanguageIfNeeded(for variantID: String) {
        guard let variant = ModelCatalog.variant(id: variantID) else { return }
        if case .some(.only(let codes)) = variant.languageScope, codes == ["en"] {
            model.settings.language = "en"
        }
    }

    private func startDownload(for variant: String) {
        guard !ModelStore.shared.isInstalled(variant) else { return }
        Task {
            do {
                _ = try await ModelStore.shared.download(variant: variant)
            } catch {
                model.lastError = error.localizedDescription
            }
        }
    }
}

struct ModelVariantRow: View {
    let variant: ModelVariant
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(variant.displayName).font(.body.weight(.semibold))
                        Spacer()
                        Text(humanSize).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(variant.tagline).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        if isEnglishOnly {
                            Tag("English only")
                        } else {
                            Tag("Multilingual")
                        }
                        Tag(variant.engineID == .parakeet ? "Parakeet" : "Whisper")
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.15),
                                  lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var isEnglishOnly: Bool {
        if case .some(.only(let codes)) = variant.languageScope, codes == ["en"] { return true }
        return false
    }

    private var humanSize: String {
        let mb = Double(variant.sizeBytes) / 1_000_000
        if mb >= 1000 {
            return String(format: "%.1f GB", mb / 1000)
        }
        return String(format: "%.0f MB", mb)
    }
}

private struct Tag: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                Capsule().fill(Color.secondary.opacity(0.12))
            )
            .foregroundStyle(.secondary)
    }
}
