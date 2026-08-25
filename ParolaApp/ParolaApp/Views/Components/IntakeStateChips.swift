import SwiftUI
import ParolaCore

/// Read-only echo of the two settings a dropped file commits to, shown wherever intake happens
/// so a bare drop isn't a guess.
struct IntakeStateChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            IntakeStateChip(systemImage: "cpu", text: modelLabel)
                .help("Model a new transcription will use")
            IntakeStateChip(systemImage: "globe", text: languageLabel)
                .help("Language a new transcription will use")
        }
    }

    private var modelLabel: String {
        guard let variant = ModelCatalog.variant(id: model.selectedModel) else {
            return AppModel.modelLabel(model.selectedModel)
        }
        return ModelPickerView.shortLabel(for: variant.displayName)
    }

    private var languageLabel: String {
        guard let code = model.selectedLanguage else { return String(localized: "Auto") }
        return SupportedLanguages.displayName(for: code)
    }
}

struct IntakeStateChip: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(DS.Font.caption2)
            Text(verbatim: text)
                .font(DS.Font.captionMedium)
        }
        .foregroundStyle(DS.Color.secondaryText)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Capsule(style: .continuous).fill(DS.Palette.subtleFill))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(DS.Color.separator.opacity(0.4), lineWidth: 0.5)
        )
    }
}
