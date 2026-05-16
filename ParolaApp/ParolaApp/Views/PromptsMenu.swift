import SwiftUI
import ParolaCore

struct PromptsMenu: View {
    @EnvironmentObject var model: AppModel
    @State private var userPrompts: [Prompt] = []

    var body: some View {
        Menu {
            ForEach(Prompt.builtIns) { prompt in
                Button(prompt.name) { model.runPrompt(prompt) }
            }
            if !userPrompts.isEmpty {
                Divider()
                ForEach(userPrompts) { prompt in
                    Button(prompt.name) { model.runPrompt(prompt) }
                }
            }
        } label: {
            if model.isRunningPrompt {
                ProgressView().controlSize(.small)
            } else {
                Label("Prompts", systemImage: "sparkles")
            }
        }
        .help("Run a prompt over the current transcript.")
        .task {
            userPrompts = await model.promptLibrary.userPrompts
        }
    }
}
