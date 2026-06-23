import SwiftUI
import ParolaCore

struct FindReplaceSettings: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var filter: RuleFilter = .all

    private enum RuleFilter: String, CaseIterable, Identifiable {
        case all, enabled, disabled, regex
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .enabled: return "Enabled"
            case .disabled: return "Disabled"
            case .regex: return "Regex"
            }
        }
    }

    private var visibleRuleIDs: Set<FindReplaceRule.ID> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Set(
            model.findReplaceRules
                .filter { matches($0, query: trimmed) }
                .map(\.id)
        )
    }

    private func matches(_ rule: FindReplaceRule, query: String) -> Bool {
        let filterOK: Bool = {
            switch filter {
            case .all: return true
            case .enabled: return rule.enabled
            case .disabled: return !rule.enabled
            case .regex: return rule.regex
            }
        }()
        guard filterOK else { return false }
        guard !query.isEmpty else { return true }
        return rule.find.localizedCaseInsensitiveContains(query)
            || rule.replace.localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        @Bindable var model = model
        let visible = visibleRuleIDs
        return Form {
            Section {
                if visible.isEmpty && !model.findReplaceRules.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach($model.findReplaceRules) { $rule in
                        if visible.contains(rule.id) {
                            FindReplaceRuleRow(rule: $rule) {
                                model.findReplaceRules.removeAll { $0.id == rule.id }
                            }
                        }
                    }
                }
                Button {
                    model.findReplaceRules.append(FindReplaceRule(find: "", replace: ""))
                } label: {
                    Label("Add rule", systemImage: "plus.circle")
                }
            } header: {
                Text("Substitutions")
            } footer: {
                Text("Applied to every new transcript before it's saved.")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            filterBar
        }
        .searchable(text: $query, prompt: "Search rules")
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RuleFilter.allCases) { option in
                    FilterChip(
                        label: option.label,
                        isSelected: filter == option
                    ) {
                        filter = option
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

}

private struct FindReplaceRuleRow: View {
    @Binding var rule: FindReplaceRule
    let onDelete: () -> Void

    @State private var cachedRegexError: String?

    private var regexError: String? {
        guard rule.regex,
              !rule.find.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return cachedRegexError
    }

    private var canEnable: Bool {
        !rule.find.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && regexError == nil
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { rule.enabled && canEnable },
            set: { if canEnable { rule.enabled = $0 } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Enabled", isOn: enabledBinding)
                    .labelsHidden()
                    .disabled(!canEnable)
                TextField("find", text: $rule.find)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(regexError == nil ? .clear : .red.opacity(0.8), lineWidth: 1)
                    )
                Text("→").foregroundStyle(.secondary)
                TextField("replace", text: $rule.replace)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(Text("Delete rule"))
            }
            HStack(spacing: 16) {
                Toggle("Case-sensitive", isOn: $rule.caseSensitive)
                Toggle("Regex", isOn: $rule.regex)
            }
            .font(.caption)
            .toggleStyle(.switch)
            .controlSize(.small)
            if let regexError {
                Label(regexError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 6)
        .onAppear { cachedRegexError = GlobalFindReplace.validate(rule) }
        .onChange(of: rule.find) { _, _ in cachedRegexError = GlobalFindReplace.validate(rule) }
        .onChange(of: rule.regex) { _, _ in cachedRegexError = GlobalFindReplace.validate(rule) }
    }
}

private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor : Color(.secondarySystemFill))
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
