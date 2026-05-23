import SwiftUI
import ParolaCore
import ParolaDictation

struct URLRuleRow: View {
    let app: (bundleID: String, name: String)
    let index: Int
    let rule: DictationWorkflow
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
                .frame(width: 14)
            TextField(String(localized: "Example: gmail.com"), text: urlPatternBinding)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)

            Picker("", selection: promptBinding) {
                Text("Default prompt").tag("")
                ForEach(Prompt.builtIns) { prompt in
                    Text(prompt.name).tag(prompt.id.uuidString)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 140)

            Picker("", selection: languageBinding) {
                Text("Default language").tag("")
                ForEach(WorkflowLanguageOptions.options, id: \.code) { option in
                    Text(option.name).tag(option.code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 110)

            Picker("", selection: insertionBinding) {
                Text("Paste").tag(DictationInsertionMode.paste)
                Text("Keystrokes").tag(DictationInsertionMode.keystroke)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 110)

            Button(role: .destructive) {
                model.removeDictationURLRule(for: app.bundleID, at: index)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 6)
    }

    private var urlPatternBinding: Binding<String> {
        Binding(
            get: { rule.urlPattern ?? "" },
            set: { newValue in
                model.updateDictationURLRule(for: app.bundleID, at: index) { $0.urlPattern = newValue }
            }
        )
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
