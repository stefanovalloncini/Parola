import SwiftUI
import ParolaCore

struct IgnoredSegmentsSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach($model.ignoredSegmentRules) { $rule in
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
    }
}
