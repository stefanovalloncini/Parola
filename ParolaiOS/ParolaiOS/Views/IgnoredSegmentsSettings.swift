import SwiftUI
import ParolaCore

struct IgnoredSegmentsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var filter: RuleFilter = .all
    @State private var addedCount: Int?

    var body: some View {
        @Bindable var model = model
        return Form {
            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(RuleFilter.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
            }

            Section {
                if filteredRuleIDs.isEmpty, !model.ignoredSegmentRules.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach($model.ignoredSegmentRules) { $rule in
                        if filteredRuleIDs.contains(rule.id) {
                            HStack {
                                Toggle("Enabled", isOn: $rule.enabled).labelsHidden()
                                TextField("e.g. uh, um, hmm", text: $rule.pattern)
                                    .textFieldStyle(.roundedBorder)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                Button(role: .destructive) {
                                    model.ignoredSegmentRules.removeAll { $0.id == rule.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .accessibilityLabel(Text("Delete rule"))
                            }
                        }
                    }
                }
                Button {
                    model.ignoredSegmentRules.append(IgnoredSegmentRule(pattern: ""))
                } label: {
                    Label("Add pattern", systemImage: "plus.circle")
                }
                Button {
                    addedCount = model.addSuggestedIgnoredPhrases()
                } label: {
                    Label("Add suggested phrases", systemImage: "text.badge.plus")
                }
                .disabled(SuggestedIgnoredPhrases.missing(from: model.ignoredSegmentRules).isEmpty)
            } header: {
                Text("Patterns")
            } footer: {
                Text(footer)
            }
        }
        .searchable(text: $query, prompt: "Search patterns")
    }

    private var footer: String {
        let base = "Segments whose text exactly matches a pattern, ignoring case and punctuation around it, are removed from the transcript before it's saved. Suggested phrases are ones speech models sometimes invent over silence or music."
        guard let addedCount else { return base }
        return base + (addedCount == 0 ? " No new phrases." : " Phrases added: \(addedCount).")
    }

    private var filteredRuleIDs: Set<IgnoredSegmentRule.ID> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Set(
            model.ignoredSegmentRules
                .filter { filter.matches($0.enabled) }
                .filter { rule in
                    guard !trimmed.isEmpty else { return true }
                    return rule.pattern.lowercased().contains(trimmed)
                }
                .map(\.id)
        )
    }
}
