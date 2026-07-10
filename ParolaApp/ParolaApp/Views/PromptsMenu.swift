import SwiftUI
import ParolaCore

struct PromptsMenu: View {
    @Environment(AppModel.self) private var model
    @State private var userPrompts: [Prompt] = []

    var body: some View {
        Menu {
            Group {
                ForEach(Prompt.builtIns) { prompt in
                    Button(prompt.name) { model.runPrompt(prompt) }
                        .accessibilityIdentifier("prompts.\(Self.identifierSlug(prompt.name))")
                        .axLeaf("Toolbar.MenuItem.BuiltinPrompt.\(Self.identifierSlug(prompt.name))")
                }
                Divider()
                Button("YouTube Chapters") { model.generateYouTubeChapters() }
                    .accessibilityIdentifier("prompts.youtube_chapters")
                    .axLeaf("Toolbar.MenuItem.YouTubeChapters")
                Button("Speakers…") { model.showingSpeakersSheet = true }
                    .accessibilityIdentifier("prompts.speakers")
                    .axLeaf("Toolbar.MenuItem.Speakers")
                if !userPrompts.isEmpty {
                    Divider()
                    ForEach(userPrompts) { prompt in
                        Button(prompt.name) { model.runPrompt(prompt) }
                            .accessibilityIdentifier("prompts.\(Self.identifierSlug(prompt.name))")
                            .axLeaf("Toolbar.MenuItem.UserPrompt.\(Self.identifierSlug(prompt.name))")
                    }
                }
            }
            // The toolbar keeps this view alive, so .task runs once; re-read on every
            // open or prompts added/renamed/deleted in Settings never show up here.
            .onAppear {
                Task { userPrompts = await model.promptLibrary.userPrompts }
            }
        } label: {
            if model.isRunningPrompt {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "sparkles")
            }
        }
        .menuIndicator(.hidden)
        .modifier(PromptsMenuHelp(isRunning: model.isRunningPrompt))
        .accessibilityIdentifier("toolbar.prompts")
        .axLeaf("Toolbar.Menu.Prompts")
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

private struct PromptsMenuHelp: ViewModifier {
    let isRunning: Bool
    func body(content: Content) -> some View {
        content.help(isRunning ? "Running prompt…" : "Run a prompt against the transcript")
    }
}
