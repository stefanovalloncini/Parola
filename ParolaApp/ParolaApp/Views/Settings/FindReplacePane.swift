import SwiftUI
import ParolaCore

struct FindReplacePane: View {
    @Environment(AppModel.self) private var model
    @State private var query = RuleListQuery()

    var body: some View {
        SettingsForm {
            if query.showsToolbar(ruleCount: model.findReplaceRules.count) {
                RuleListToolbar(query: $query, placeholder: "Search rules…", leafPrefix: "FindReplace")
            }

            SettingsSection {
                let visible = visibleRules
                if model.findReplaceRules.isEmpty {
                    InlineEmptyText("No rules yet")
                } else if visible.isEmpty {
                    HStack {
                        Text("No rules match.").foregroundStyle(DS.Color.secondaryText).font(DS.Font.body)
                        Spacer()
                    }
                } else {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { idx, rule in
                        if let binding = binding(for: rule.id) {
                            FindReplaceRuleRow(rule: binding, isFirst: idx == 0) {
                                model.findReplaceRules.removeAll { $0.id == rule.id }
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    query.showNewRule()
                    model.findReplaceRules.append(FindReplaceRule(find: "", replace: ""))
                } label: {
                    Label("Add Rule", systemImage: "plus.circle")
                }
                .axLeaf("FindReplace.Button.AddRule")
                Spacer()
                Menu {
                    Button("Tech Terms (English)") { model.importBundledTermPack(named: "tech-terms-en") }
                        .axLeaf("FindReplace.MenuItem.PackTechTermsEn")
                    Button("Termini tecnici (Italiano)") { model.importBundledTermPack(named: "tech-terms-it") }
                        .axLeaf("FindReplace.MenuItem.PackTechTermsIt")
                    Divider()
                    Button("Import from File…") { model.presentTermPackImporter() }
                        .axLeaf("FindReplace.MenuItem.ImportFromFile")
                } label: {
                    Label("Import Pack", systemImage: "tray.and.arrow.down")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .axLeaf("FindReplace.Menu.ImportPack")

                Button {
                    model.presentTermPackExporter()
                } label: {
                    Label("Export Pack", systemImage: "tray.and.arrow.up")
                }
                .disabled(model.findReplaceRules.isEmpty)
                .axLeaf("FindReplace.Button.ExportPack")
            }

            SettingHelper(text: "Term packs add curated rules in one click.")
            ResetPaneButton(scope: .findReplace)
        }
    }

    private var visibleRules: [FindReplaceRule] {
        query.arrange(model.findReplaceRules, fields: { [$0.find, $0.replace] }, isEnabled: Self.isEffectivelyEnabled)
    }

    static func isEffectivelyEnabled(_ rule: FindReplaceRule) -> Bool {
        let trimmed = rule.find.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rule.enabled, !trimmed.isEmpty else { return false }
        if rule.regex, (try? NSRegularExpression(pattern: trimmed)) == nil { return false }
        return true
    }

    // Resolved by id on every access: an index captured at render time can go stale
    // when a row is deleted before a pending write lands.
    private func binding(for id: FindReplaceRule.ID) -> Binding<FindReplaceRule>? {
        guard let current = model.findReplaceRules.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { model.findReplaceRules.first(where: { $0.id == id }) ?? current },
            set: { newValue in
                guard let idx = model.findReplaceRules.firstIndex(where: { $0.id == id }) else { return }
                model.findReplaceRules[idx] = newValue
            }
        )
    }
}

private struct FindReplaceRuleRow: View {
    @Binding var rule: FindReplaceRule
    let isFirst: Bool
    let onDelete: () -> Void

    @State private var cachedRegexError: String?

    private var canEnable: Bool {
        !rule.find.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && regexError == nil
    }

    private var regexError: String? {
        guard rule.regex else { return nil }
        let trimmed = rule.find.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return cachedRegexError
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { rule.enabled && canEnable },
            set: { if canEnable { rule.enabled = $0 } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Toggle("Use this rule", isOn: enabledBinding)
                        .labelsHidden()
                        .disabled(!canEnable)
                        .axLeaf("FindReplace.Toggle.RuleEnabled")
                    TextField("find", text: $rule.find, prompt: Text("find"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                                .strokeBorder(regexError == nil ? Color.clear : DS.Color.danger.opacity(0.8), lineWidth: 1)
                        )
                        .axLeaf("FindReplace.TextField.Find")
                    Text("→").foregroundStyle(DS.Color.secondaryText)
                    TextField("replace with", text: $rule.replace, prompt: Text("replace with"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .axLeaf("FindReplace.TextField.Replace")
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .axLeaf("FindReplace.Button.DeleteRule")
                }
                HStack(spacing: 16) {
                    Toggle("Case-sensitive", isOn: $rule.caseSensitive).toggleStyle(.checkbox)
                        .axLeaf("FindReplace.Toggle.CaseSensitive")
                    Toggle("Regex", isOn: $rule.regex).toggleStyle(.checkbox)
                        .axLeaf("FindReplace.Toggle.Regex")
                }
                .font(DS.Font.secondary)
                if let regexError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DS.Color.dangerText)
                        Text(regexError)
                            .foregroundStyle(DS.Color.dangerText)
                    }
                    .font(DS.Font.secondary)
                }
            }
        }
        .onAppear { cachedRegexError = GlobalFindReplace.validate(rule) }
        .onChange(of: rule.find) { cachedRegexError = GlobalFindReplace.validate(rule) }
        .onChange(of: rule.caseSensitive) { cachedRegexError = GlobalFindReplace.validate(rule) }
        .onChange(of: rule.regex) { cachedRegexError = GlobalFindReplace.validate(rule) }
    }
}
