import SwiftUI
import ParolaCore

struct IgnoredSegmentsSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var filter: RuleFilter = .all

    var body: some View {
        Form {
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
                            }
                        }
                    }
                }
                Button {
                    model.ignoredSegmentRules.append(IgnoredSegmentRule(pattern: ""))
                } label: {
                    Label("Add pattern", systemImage: "plus.circle")
                }
            } header: {
                Text("Patterns")
            } footer: {
                Text("Segments whose text exactly matches a pattern (case-insensitive, trimmed) are removed from the transcript before it's saved.")
            }
        }
        .searchable(text: $query, prompt: "Search patterns")
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
