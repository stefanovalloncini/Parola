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
        Menu {
            ForEach(languages, id: \.name) { lang in
                Button(lang.name) { model.selectedLanguage = lang.code }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                Text(currentLabel).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var currentLabel: String {
        if let code = model.selectedLanguage {
            return languages.first { $0.code == code }?.name ?? code
        }
        return "Auto"
    }
}
