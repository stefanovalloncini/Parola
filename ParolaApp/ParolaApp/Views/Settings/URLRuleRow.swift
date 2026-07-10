import SwiftUI
import ParolaCore
import ParolaDictation

struct URLRuleRow: View {
    let app: (bundleID: String, name: String)
    let index: Int
    let rule: DictationWorkflow
    @Environment(AppModel.self) private var model
    @State private var draftPattern = ""
    @FocusState private var patternFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
                .frame(width: 14)
            TextField(String(localized: "Example: gmail.com"), text: $draftPattern)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .focused($patternFocused)
                .onAppear { draftPattern = rule.urlPattern ?? "" }
                .onChange(of: rule.urlPattern) { draftPattern = rule.urlPattern ?? "" }
                .onSubmit { commitPattern() }
                .onChange(of: patternFocused) {
                    if !patternFocused { commitPattern() }
                }
                .axLeaf("URLRule.TextField.Pattern")

            Picker("", selection: promptBinding) {
                Text("Default prompt").tag("")
                ForEach(Prompt.builtIns) { prompt in
                    Text(prompt.name).tag(prompt.id.uuidString)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 140)
            .axLeaf("URLRule.Picker.Prompt")

            Picker("", selection: languageBinding) {
                Text("Default language").tag("")
                ForEach(WorkflowLanguageOptions.options, id: \.code) { option in
                    Text(option.name).tag(option.code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 110)
            .axLeaf("URLRule.Picker.Language")

            Picker("", selection: insertionBinding) {
                Text("Paste").tag(DictationInsertionMode.paste)
                Text("Keystrokes").tag(DictationInsertionMode.keystroke)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 110)
            .axLeaf("URLRule.Picker.Insertion")

            Button(role: .destructive) {
                model.removeDictationURLRule(for: app.bundleID, at: index)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .axLeaf("URLRule.Button.Remove")
        }
        .padding(.leading, 6)
    }

    // Commits on submit or focus loss. An empty pattern reverts to the stored value —
    // deleting the rule is the minus button's job, not a side effect of clearing the field.
    private func commitPattern() {
        let trimmed = draftPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            draftPattern = rule.urlPattern ?? ""
        } else if trimmed != (rule.urlPattern ?? "") {
            model.updateDictationURLRule(for: app.bundleID, at: index) { $0.urlPattern = trimmed }
        }
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { rule.promptID ?? "" },
            set: { newValue in
                model.updateDictationURLRule(for: app.bundleID, at: index) {
                    $0.promptID = newValue.isEmpty ? nil : newValue
                }
            }
        )
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { rule.language ?? "" },
            set: { newValue in
                model.updateDictationURLRule(for: app.bundleID, at: index) {
                    $0.language = newValue.isEmpty ? nil : newValue
                }
            }
        )
    }

    private var insertionBinding: Binding<DictationInsertionMode> {
        Binding(
            get: { rule.insertion ?? .paste },
            set: { newValue in
                model.updateDictationURLRule(for: app.bundleID, at: index) {
                    $0.insertion = (newValue == .paste) ? nil : newValue
                }
            }
        )
    }
}
