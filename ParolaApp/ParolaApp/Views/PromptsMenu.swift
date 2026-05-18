import SwiftUI
import ParolaCore

struct PromptsMenu: View {
    @EnvironmentObject var model: AppModel
    @State private var userPrompts: [Prompt] = []

    var body: some View {
        Menu {
            ForEach(Prompt.builtIns) { prompt in
                Button(prompt.name) { model.runPrompt(prompt) }
                    .accessibilityIdentifier("prompts.\(Self.identifierSlug(prompt.name))")
            }
            Divider()
            Button("YouTube Chapters") { model.generateYouTubeChapters() }
                .accessibilityIdentifier("prompts.youtube_chapters")
            Button("Speakers…") { model.showingSpeakersSheet = true }
                .accessibilityIdentifier("prompts.speakers")
            if !userPrompts.isEmpty {
                Divider()
                ForEach(userPrompts) { prompt in
                    Button(prompt.name) { model.runPrompt(prompt) }
                        .accessibilityIdentifier("prompts.\(Self.identifierSlug(prompt.name))")
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
        .accessibilityIdentifier("toolbar.prompts")
        .task {
            userPrompts = await model.promptLibrary.userPrompts
        }
    }

    private static func identifierSlug(_ name: String) -> String {
        name
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
