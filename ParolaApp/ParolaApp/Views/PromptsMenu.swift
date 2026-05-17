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
            Divider()
            Button("YouTube Chapters") { model.generateYouTubeChapters() }
            Button("Speakers…") { model.showingSpeakersSheet = true }
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
                Image(systemName: "sparkles")
            }
        }
        .menuIndicator(.hidden)
        .help(model.isRunningPrompt ? "Running prompt…" : "Run a prompt against the transcript")
        .task {
            userPrompts = await model.promptLibrary.userPrompts
        }
    }
}
