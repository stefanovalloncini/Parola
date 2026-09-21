import SwiftUI
import ParolaCore

struct LanguagePickerView: View {
    @Environment(AppModel.self) private var model
    var shell: PillPickerShell = .segment
    var leaf: String? = nil

    var body: some View {
        PillPickerButton(icon: "globe", caption: String(localized: "Language"), value: currentLabel, shell: shell, popoverWidth: 300, leaf: leaf) {
            LanguagePickerPopover()
        }
    }

    private var currentLabel: String {
        guard let code = model.selectedLanguage else {
            // Auto on an English-only model runs as English regardless (TranscriptionSession pins
            // it); showing that here beats a label that's true about the setting but not the run.
            return model.selectedModelCapabilities.supportedLanguages.isEnglishOnly
                ? SupportedLanguages.displayName(for: "en") : LanguagePickerPopover.autoLabel
        }
        return SupportedLanguages.displayName(for: code)
    }
}

struct LanguagePickerPopover: View {
    @Environment(AppModel.self) private var model

    static var autoLabel: String { String(localized: "Auto-detect") }

    var body: some View {
        VStack(spacing: 0) {
            PillPopoverRow(
                title: Self.autoLabel,
                subtitle: String(localized: "Identified from the audio"),
                isSelected: model.selectedLanguage == nil,
                leading: .symbol("waveform.badge.magnifyingglass", tint: DS.Color.accent),
                minHeight: PillPopoverRow.twoLineHeight,
                action: { model.selectedLanguage = nil }
            )
            Divider()
                .padding(.horizontal, DS.Spacing.small)
                .padding(.vertical, DS.Spacing.tight)
            PillPopoverList {
                ForEach(SupportedLanguages.codes, id: \.self) { code in
                    let note = Self.supportNote(for: code, scope: scope, modelName: modelName)
                    PillPopoverRow(
                        title: SupportedLanguages.displayName(for: code),
                        subtitle: note ?? SupportedLanguages.endonym(for: code),
                        subtitleTint: note == nil ? nil : DS.Color.warningText,
                        isSelected: code == model.selectedLanguage,
                        isDimmed: note != nil,
                        leading: .monogram(code.uppercased()),
                        minHeight: PillPopoverRow.twoLineHeight,
                        action: { model.selectedLanguage = code }
                    )
                }
            }
        }
        .padding(.horizontal, DS.Spacing.snug)
    }

    /// A pick the model can't honour still goes through (the toolbar warns), but the row says so first.
    static func supportNote(for code: String, scope: ParolaCore.SupportedLanguages, modelName: String) -> String? {
        scope.allows(code) ? nil : String(localized: "Not supported by \(modelName)")
    }

    private var scope: ParolaCore.SupportedLanguages {
        model.selectedModelCapabilities.supportedLanguages
    }

    private var modelName: String {
        guard let variant = ModelCatalog.variant(id: model.selectedModel) else { return model.selectedModel }
        return ModelPickerView.shortLabel(for: variant.displayName)
    }
}
