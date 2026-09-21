import SwiftUI
import ParolaCore

struct PromptsMenu: View {
    @Environment(AppModel.self) private var model
    @State private var userPrompts: [Prompt] = []

    var body: some View {
        Menu {
            Group {
                if !model.isAIAvailable(for: .prompts), let reason = model.aiUnavailableReason {
                    Text(verbatim: reason)
                    Divider()
                }
                Group {
                    ForEach(Prompt.builtIns) { prompt in
                        Button(prompt.name) { model.runPrompt(prompt) }
                            .accessibilityIdentifier("prompts.\(Self.identifierSlug(prompt.name))")
                            .axLeaf("HeaderBar.MenuItem.BuiltinPrompt.\(Self.identifierSlug(prompt.name))")
                    }
                    Divider()
                    Button("YouTube Chapters") { model.generateYouTubeChapters() }
                        .accessibilityIdentifier("prompts.youtube_chapters")
                        .axLeaf("HeaderBar.MenuItem.YouTubeChapters")
                }
                .disabled(!model.isAIAvailable(for: .prompts))
                Button("Speakers…") { model.showingSpeakersSheet = true }
                    .accessibilityIdentifier("prompts.speakers")
                    .axLeaf("HeaderBar.MenuItem.Speakers")
                if !userPrompts.isEmpty {
                    Divider()
                    ForEach(userPrompts) { prompt in
                        Button(prompt.name) { model.runPrompt(prompt) }
                            .accessibilityIdentifier("prompts.\(Self.identifierSlug(prompt.name))")
                            .axLeaf("HeaderBar.MenuItem.UserPrompt.\(Self.identifierSlug(prompt.name))")
                    }
                    .disabled(!model.isAIAvailable(for: .prompts))
                }
            }
            // The toolbar keeps this view alive, so .task runs once; re-read on every
            // open or prompts added/renamed/deleted in Settings never show up here.
            .onAppear {
                Task { userPrompts = await model.promptLibrary.userPrompts }
                model.refreshAIAvailability()
            }
        } label: {
            if model.isRunningPrompt {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "wand.and.stars")
            }
        }
        .menuIndicator(.hidden)
        .modifier(PromptsMenuHelp(
            isRunning: model.isRunningPrompt,
            unavailableReason: model.isAIAvailable(for: .prompts) ? nil : model.aiUnavailableReason
        ))
        .accessibilityIdentifier("toolbar.prompts")
        .axLeaf("HeaderBar.Menu.Prompts")
        .task {
            userPrompts = await model.promptLibrary.userPrompts
            model.refreshAIAvailability()
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
    let unavailableReason: String?

    func body(content: Content) -> some View {
        if let unavailableReason {
            content.help(Text(verbatim: unavailableReason))
        } else {
            content.help(isRunning ? "Running prompt…" : "Run a prompt against the transcript")
        }
    }
}
