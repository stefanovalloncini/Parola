import SwiftUI
import ParolaCore

struct PromptsMenu: View {
    @EnvironmentObject var model: AppModel
    @State private var userPrompts: [Prompt] = []

    private let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

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
            label
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Run a prompt over the current transcript.")
        .task {
            userPrompts = await model.promptLibrary.userPrompts
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            iconBadge

            VStack(alignment: .leading, spacing: 0) {
                Text("Prompts")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(activeLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 36)
        .background(shape.fill(Color.secondary.opacity(0.15)))
        .contentShape(shape)
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DS.Color.accent.opacity(0.18))
            if model.isRunningPrompt {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Color.accent)
            }
        }
        .frame(width: 22, height: 22)
    }

    private var activeLabel: String {
        if model.isRunningPrompt { return "Running…" }
        if let name = model.promptOutput?.promptName { return name }
        return "Choose…"
    }
}
