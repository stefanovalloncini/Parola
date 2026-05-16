import SwiftUI
import ParolaCore

struct PromptsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                let prompts = Prompt.builtIns
                ForEach(Array(prompts.enumerated()), id: \.element.id) { idx, prompt in
                    SettingRow(prompt.name, isFirst: idx == 0) {
                        Text("Built-in").foregroundStyle(.secondary)
                    }
                }
            }
            SettingHelper(text: "Prompts rewrite transcripts after recording — used by dictation cleanup and the Transcript menu.")
        }
    }
}
