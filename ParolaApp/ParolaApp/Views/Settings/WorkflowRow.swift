import SwiftUI
import ParolaCore
import ParolaDictation

struct WorkflowRow: View {
    let app: (bundleID: String, name: String)
    let isFirst: Bool
    let isRemovable: Bool
    @Environment(AppModel.self) private var model

    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.microsoft.edgemac"
    ]

    private var isBrowser: Bool { Self.browserBundleIDs.contains(app.bundleID) }

    private var urlRules: [DictationWorkflow] {
        model.urlDictationRules(for: app.bundleID)
    }

    var body: some View {
        SettingRow(titleVerbatim: app.name, isFirst: isFirst) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    promptPicker
                    languagePicker
                    insertionPicker
                    if isRemovable {
                        Button(role: .destructive) {
                            model.removeDictationOverride(for: app.bundleID)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if isBrowser {
                    ForEach(Array(urlRules.enumerated()), id: \.offset) { idx, rule in
                        URLRuleRow(app: app, index: idx, rule: rule)
                    }
                    HStack {
                        Button {
                            model.addDictationURLRule(for: app.bundleID)
                        } label: {
                            Label("Add URL rule", systemImage: "plus.circle")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
    }

    private var promptPicker: some View {
        Picker("", selection: promptBinding) {
            Text("Default prompt").tag("")
            ForEach(Prompt.builtIns) { prompt in
                Text(prompt.name).tag(prompt.id.uuidString)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 170)
    }

    private var languagePicker: some View {
        Picker("", selection: languageBinding) {
            Text("Default language").tag("")
            ForEach(WorkflowLanguageOptions.options, id: \.code) { option in
                Text(option.name).tag(option.code)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 130)
    }

    private var insertionPicker: some View {
        Picker("", selection: insertionBinding) {
            Text("Paste").tag(DictationInsertionMode.paste)
            Text("Keystrokes").tag(DictationInsertionMode.keystroke)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 120)
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { model.dictationOverridePromptID(for: app.bundleID) },
            set: { model.setDictationOverridePromptID($0, for: app.bundleID) }
        )
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { model.dictationOverrideLanguage(for: app.bundleID) },
            set: { model.setDictationOverrideLanguage($0, for: app.bundleID) }
        )
    }

    private var insertionBinding: Binding<DictationInsertionMode> {
        Binding(
            get: { model.dictationOverrideInsertion(for: app.bundleID) },
            set: { model.setDictationOverrideInsertion($0, for: app.bundleID) }
        )
    }
}

enum WorkflowLanguageOptions {
    static let options: [(code: String, name: String)] = [
        ("en", "English"),
        ("it", "Italian"),
        ("fr", "French"),
        ("de", "German"),
        ("es", "Spanish"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ja", "Japanese"),
        ("zh", "Chinese"),
        ("ko", "Korean")
    ]
}
