import SwiftUI
import ParolaCore

struct ModelPickerView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            ForEach(model.availableModels) { entry in
                Button {
                    if entry.isInstalled {
                        model.selectedModel = entry.name
                    } else {
                        model.downloadModel(entry.name)
                        model.selectedModel = entry.name
                    }
                } label: {
                    HStack {
                        if entry.isInstalled {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                        }
                        Text(entry.label)
                        Spacer()
                        if let size = entry.approximateSizeBytes {
                            Text(humanBytes(size)).foregroundStyle(.secondary).font(.caption)
                        }
                    }
                }
            }
            Divider()
            Button("Refresh") { model.refreshModelList() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(currentLabel)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Active model. Models are downloaded on demand.")
    }

    private var currentLabel: String {
        model.availableModels.first(where: { $0.name == model.selectedModel })?.label ?? model.selectedModel
    }

    private func humanBytes(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes); var idx = 0
        while value >= 1024, idx < units.count - 1 { value /= 1024; idx += 1 }
        return String(format: "%.1f %@", value, units[idx])
    }
}

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
