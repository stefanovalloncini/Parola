import SwiftUI
import ParolaCore

/// Chapters, action items and every prompt that reads a transcript, in one menu.
struct AskAIMenu: View {
    @Environment(AppModel.self) private var model
    @State private var userPrompts: [Prompt] = []

    var body: some View {
        Menu {
            AskAIItems(userPrompts: userPrompts)
                // The toolbar keeps this view alive, so .task runs once; re-read on every
                // open or prompts added/renamed/deleted in Settings never show up here.
                .onAppear {
                    Task { userPrompts = await model.promptLibrary.userPrompts }
                    model.refreshAIAvailability()
                }
        } label: {
            Label {
                Text("Ask AI")
            } icon: {
                if model.isRunningPrompt {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                }
            }
        }
        .menuIndicator(.hidden)
        .modifier(AskAIMenuHelp(
            isRunning: model.isRunningPrompt,
            unavailableReason: model.isAIAvailable(for: .prompts) ? nil : model.aiUnavailableReason
        ))
        .axLeaf("Toolbar.Transcript.Menu.AskAI")
        .task {
            userPrompts = await model.promptLibrary.userPrompts
            model.refreshAIAvailability()
        }
    }
}

/// Ask AI's items: Stop Prompt while one runs, why AI is off, chapters and action items, then the prompts.
struct AskAIItems: View {
    @Environment(AppModel.self) private var model
    let userPrompts: [Prompt]

    var body: some View {
        if model.isRunningPrompt {
            Button("Stop Prompt") { model.stopAIRun(.prompt) }
                .axLeaf("Toolbar.Transcript.MenuItem.StopPrompt")
            Divider()
        }
        if !model.isAIAvailable(for: .prompts), let reason = model.aiUnavailableReason {
            Text(verbatim: reason)
            OpenAISettingsButton(leaf: "Toolbar.Transcript.MenuItem.OpenAISettings")
            Divider()
        }
        Button(model.smartChapters.isEmpty ? String(localized: "Generate Chapters") : String(localized: "Regenerate Chapters")) {
            runInInspector(model.extractSmartChapters)
        }
        .disabled(!model.isAIAvailable(for: .summary))
        .axLeaf("Toolbar.Transcript.MenuItem.Chapters")
        Button("Find Action Items") { runInInspector(model.extractActionItems) }
            .disabled(!model.isAIAvailable(for: .prompts))
            .axLeaf("Toolbar.Transcript.MenuItem.ActionItems")
        Divider()
        Group {
            ForEach(Self.transcriptPrompts) { prompt in
                Button(prompt.name) { model.runPrompt(prompt) }
                    .axLeaf("Toolbar.Transcript.MenuItem.BuiltinPrompt.\(Self.identifierSlug(prompt.name))")
            }
            Divider()
            Button("YouTube Chapters") { model.generateYouTubeChapters() }
                .axLeaf("Toolbar.Transcript.MenuItem.YouTubeChapters")
        }
        .disabled(!model.isAIAvailable(for: .prompts) || model.isRunningPrompt)
        if !userPrompts.isEmpty {
            Divider()
            ForEach(userPrompts) { prompt in
                Button(prompt.name) { model.runPrompt(prompt) }
                    .axLeaf("Toolbar.Transcript.MenuItem.UserPrompt.\(Self.identifierSlug(prompt.name))")
            }
            .disabled(!model.isAIAvailable(for: .prompts) || model.isRunningPrompt)
        }
        Divider()
        Button("Manage Prompts…") { model.openSettings(route: .prompts) }
            .axLeaf("Toolbar.Transcript.MenuItem.ManagePrompts")
    }

    /// Chapters and action items land in the Info inspector, so a run started here has to open it there.
    private func runInInspector(_ run: () -> Void) {
        InspectorVisibility.showInfo(in: DefaultsStore.current, isNarrow: model.transcriptPaneIsNarrow)
        run()
    }

    /// The built-ins that shape a dictation rather than read a transcript stay out, as in Chat.
    private static let transcriptPrompts = Prompt.builtIns.filter { !ChatPane.excludedBuiltInIDs.contains($0.id) }

    private static func identifierSlug(_ name: String) -> String {
        name
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

private struct AskAIMenuHelp: ViewModifier {
    let isRunning: Bool
    let unavailableReason: String?

    func body(content: Content) -> some View {
        if let unavailableReason {
            content.help(Text(verbatim: unavailableReason))
        } else {
            content.help(isRunning ? "Running prompt…" : "Chapters, action items and prompts")
        }
    }
}
