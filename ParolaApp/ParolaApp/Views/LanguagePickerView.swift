import SwiftUI

struct LanguagePickerView: View {
    @EnvironmentObject var model: AppModel

    private let languages: [(code: String?, name: String)] = [
        (nil, "Auto-detect"),
        ("en", "English"),
        ("it", "Italian"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ja", "Japanese"),
        ("zh", "Chinese"),
        ("ko", "Korean"),
        ("ar", "Arabic"),
        ("ru", "Russian"),
        ("hi", "Hindi"),
    ]

    var body: some View {
        PillPickerButton(icon: "globe", caption: "Language", value: currentLabel) {
            VStack(spacing: 0) {
                ForEach(languages, id: \.name) { lang in
                    PillPopoverRow(
                        title: lang.name,
                        isSelected: lang.code == model.selectedLanguage,
                        action: { model.selectedLanguage = lang.code }
                    )
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private var currentLabel: String {
        if let code = model.selectedLanguage {
            return languages.first { $0.code == code }?.name ?? code
        }
        return "Auto-detect"
    }
}
