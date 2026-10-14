import os
import SwiftUI
import ParolaCore

struct FindReplacePane: View {
    @Environment(AppModel.self) private var model
    @State private var query = RuleListQuery()
    @State private var selection: FindReplaceRule.ID?

    var body: some View {
        let visible = visibleRules
        return SettingsForm {
            Section {
                if model.findReplaceRules.isEmpty {
                    InlineEmptyText("No rules yet")
                } else if visible.isEmpty {
                    InlineEmptyText("No rules match.")
                } else {
                    RuleListRows(
                        visible, selection: $selection, leaf: "FindReplace.Row", label: { "\($0.find) → \($0.replace)" },
                        removeLabel: "Remove Rule", onRemove: remove
                    ) { rule in
                        if let binding = binding(for: rule.id) {
                            FindReplaceRuleRow(rule: binding)
                        }
                    }
                }
                RuleListBar(
                    leafPrefix: "FindReplace", addLabel: "Add Rule", removeLabel: "Remove Rule",
                    canRemove: visible.contains { $0.id == selection },
                    onAdd: add, onRemove: removeSelected
                ) {
                    Menu("Import Pack") {
                        Button("Tech Terms (English)") { model.importBundledTermPack(named: "tech-terms-en") }
                            .axLeaf("FindReplace.MenuItem.PackTechTermsEn")
                        Button("Termini tecnici (Italiano)") { model.importBundledTermPack(named: "tech-terms-it") }
                            .axLeaf("FindReplace.MenuItem.PackTechTermsIt")
                        Divider()
                        Button("Import from File…") { model.presentTermPackImporter() }
                            .axLeaf("FindReplace.MenuItem.ImportFromFile")
                    }
                    .axLeaf("FindReplace.Menu.ImportPack")
                    Button("Export Pack") { model.presentTermPackExporter() }
                        .disabled(model.findReplaceRules.isEmpty)
                        .axLeaf("FindReplace.MenuItem.ExportPack")
                }
            } header: {
                if query.showsToolbar(ruleCount: model.findReplaceRules.count) {
                    RuleListToolbar(query: $query, placeholder: "Search rules…", leafPrefix: "FindReplace")
                }
            }

            SettingHelper(text: "Term packs add curated rules in one click.")
            ResetPaneButton(scope: .findReplace)
        }
        .alert(
            model.pendingRuleImport?.title ?? "",
            isPresented: Binding(
                get: { model.pendingRuleImport != nil },
                set: { if !$0 { model.cancelRuleImport() } }
            ),
            presenting: model.pendingRuleImport
        ) { pending in
            if pending.newRuleCount > 0 {
                Button("Import") { model.confirmRuleImport() }
                    .axLeaf("FindReplace.Button.ImportConfirm")
                Button("Cancel", role: .cancel) { model.cancelRuleImport() }
                    .axLeaf("FindReplace.Button.ImportCancel")
            } else {
                Button("OK", role: .cancel) { model.cancelRuleImport() }
                    .axLeaf("FindReplace.Button.ImportOK")
            }
        } message: { pending in
            Text(verbatim: pending.message)
        }
    }

    private func add() {
        query.showNewRule()
        let rule = FindReplaceRule(find: "", replace: "")
        model.findReplaceRules.append(rule)
        selection = rule.id
    }

    private func removeSelected() {
        guard let selection else { return }
        remove(selection)
    }

    private func remove(_ id: FindReplaceRule.ID) {
        model.findReplaceRules.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }

    private var visibleRules: [FindReplaceRule] {
        query.arrange(model.findReplaceRules, fields: { [$0.find, $0.replace] }, isEnabled: Self.isEffectivelyEnabled)
    }

    static func isEffectivelyEnabled(_ rule: FindReplaceRule) -> Bool {
        let trimmed = rule.find.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rule.enabled, !trimmed.isEmpty else { return false }
        if rule.regex, !CompiledPatterns.shared.compiles(trimmed) { return false }
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
                    .selectsRuleRowOnFocus()
                    .axLeaf("FindReplace.TextField.Find")
                Text("→").foregroundStyle(DS.Color.secondaryText)
                TextField("replace with", text: $rule.replace, prompt: Text("replace with"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .selectsRuleRowOnFocus()
                    .axLeaf("FindReplace.TextField.Replace")
            }
            HStack(spacing: 16) {
                Toggle("Case-sensitive", isOn: $rule.caseSensitive).toggleStyle(.checkbox)
                    .axLeaf("FindReplace.Toggle.CaseSensitive")
                Toggle("Whole words", isOn: Binding(get: { rule.wholeWord }, set: { rule.setWholeWord($0) }))
                    .toggleStyle(.checkbox)
                    .axLeaf("FindReplace.Toggle.WholeWords")
                Toggle("Regex", isOn: Binding(get: { rule.regex }, set: { rule.setRegex($0) }))
                    .toggleStyle(.checkbox)
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
        .onAppear { cachedRegexError = GlobalFindReplace.validate(rule) }
        .onChange(of: rule.find) { cachedRegexError = GlobalFindReplace.validate(rule) }
        .onChange(of: rule.caseSensitive) { cachedRegexError = GlobalFindReplace.validate(rule) }
        .onChange(of: rule.regex) { cachedRegexError = GlobalFindReplace.validate(rule) }
    }
}

/// Whether a pattern compiles, remembered so the rule list doesn't compile every regex again on each pass.
final class CompiledPatterns: Sendable {
    static let shared = CompiledPatterns()
    private static let limit = 256
    private let verdicts = OSAllocatedUnfairLock(initialState: [String: Bool]())
    private let compiled = OSAllocatedUnfairLock(initialState: 0)

    var compilations: Int { compiled.withLock { $0 } }

    func compiles(_ pattern: String) -> Bool {
        if let known = verdicts.withLock({ $0[pattern] }) { return known }
        compiled.withLock { $0 += 1 }
        let verdict = (try? NSRegularExpression(pattern: pattern)) != nil
        verdicts.withLock { table in
            if table.count >= Self.limit { table.removeAll() }
            table[pattern] = verdict
        }
        return verdict
    }
}
