import SwiftUI

struct LanguagePickerView: View {
    @Environment(AppModel.self) private var model

    private let codes: [String] = [
        "en", "it", "es", "fr", "de", "pt", "nl", "ja", "zh", "ko", "ar", "ru", "hi",
    ]

    private let fallbackNames: [String: String] = [
        "en": "English",
        "it": "Italian",
        "es": "Spanish",
        "fr": "French",
        "de": "German",
        "pt": "Portuguese",
        "nl": "Dutch",
        "ja": "Japanese",
        "zh": "Chinese",
        "ko": "Korean",
        "ar": "Arabic",
        "ru": "Russian",
        "hi": "Hindi",
    ]

    var body: some View {
        PillPickerButton(icon: "globe", caption: String(localized: "Language"), value: currentLabel) {
            VStack(spacing: 0) {
                PillPopoverRow(
                    title: autoLabel,
                    isSelected: model.selectedLanguage == nil,
                    action: { model.selectedLanguage = nil }
                )
                ForEach(codes, id: \.self) { code in
                    PillPopoverRow(
                        title: displayName(for: code),
                        isSelected: code == model.selectedLanguage,
                        action: { model.selectedLanguage = code }
                    )
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private var currentLabel: String {
        guard let code = model.selectedLanguage else { return autoLabel }
        return displayName(for: code)
    }

    private var autoLabel: String { String(localized: "Auto") }

    private func displayName(for code: String) -> String {
        let fallback = fallbackNames[code] ?? code
        guard let localized = Locale.current.localizedString(forLanguageCode: code) else {
            return fallback
        }
        return localized.capitalized(with: Locale.current)
    }
}
