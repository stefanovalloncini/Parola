import SwiftUI
import ParolaCore
import ParolaDictation

struct WorkflowRow: View {
    let app: (bundleID: String, name: String)
    let isRemovable: Bool
    @Environment(AppModel.self) private var model
    @State private var isAddingRule = false
    @State private var draftPattern = ""

    private var isBrowser: Bool { BrowserURLResolver.supportedBundleIDs.contains(app.bundleID) }

    private var urlRules: [DictationWorkflow] {
        model.urlDictationRules(for: app.bundleID)
    }

    var body: some View {
        SettingRow(titleVerbatim: app.name) {
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
                        .axLeaf("Workflow.Button.RemoveOverride")
                    }
                }
                if isBrowser {
                    ForEach(Array(urlRules.enumerated()), id: \.offset) { idx, rule in
                        URLRuleRow(app: app, index: idx, rule: rule)
                    }
                    if isAddingRule {
                        draftRuleRow
                    } else {
                        HStack {
                            Button {
                                isAddingRule = true
                            } label: {
                                Label("Add URL Rule", systemImage: "plus.circle")
                                    .font(DS.Font.secondary)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(DS.Color.secondaryText)
                            .axLeaf("Workflow.Button.AddURLRule")
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    private var draftRuleRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .foregroundStyle(DS.Color.secondaryText)
                .frame(width: 14)
            TextField("Example: gmail.com", text: $draftPattern, prompt: Text("Example: gmail.com"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .onSubmit(commitDraftRule)
                .axLeaf("Workflow.TextField.NewURLRule")
            Button("Add", action: commitDraftRule)
                .disabled(draftPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                .axLeaf("Workflow.Button.ConfirmURLRule")
            Button {
                isAddingRule = false
                draftPattern = ""
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(DS.Color.secondaryText)
            .axLeaf("Workflow.Button.CancelURLRule")
            Spacer()
        }
        .padding(.leading, DS.Spacing.snug)
    }

    private func commitDraftRule() {
        let pattern = draftPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        model.addDictationURLRule(for: app.bundleID, pattern: pattern)
        draftPattern = ""
        isAddingRule = false
    }

    private var promptPicker: some View {
        Picker("Cleanup prompt", selection: promptBinding) {
            Text("Default prompt").tag("")
            ForEach(Prompt.builtIns) { prompt in
                Text(prompt.name).tag(prompt.id.uuidString)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 170)
        .axLeaf("Workflow.Picker.Prompt")
    }

    private var languagePicker: some View {
        Picker("Language", selection: languageBinding) {
            Text("Default language").tag("")
            ForEach(WorkflowLanguageOptions.options, id: \.code) { option in
                Text(option.name).tag(option.code)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 130)
        .axLeaf("Workflow.Picker.Language")
    }

    private var insertionPicker: some View {
        Picker("Insert with", selection: insertionBinding) {
            Text("Paste").tag(DictationInsertionMode.paste)
            Text("Keystrokes").tag(DictationInsertionMode.keystroke)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 120, alignment: .trailing)
        .axLeaf("Workflow.Picker.Insertion")
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
    static var options: [(code: String, name: String)] { SupportedLanguages.options }
}
