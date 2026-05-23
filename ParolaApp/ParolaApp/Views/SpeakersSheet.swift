import SwiftUI
import ParolaCore

struct SpeakersSheet: View {
    let transcript: Transcript
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var renames: [String: String] = [:]
    @State private var suggestions: [Person] = []
    @State private var searchText: String = ""
    @FocusState private var focusedSpeaker: String?

    var body: some View {
        SheetFrame(
            icon: "person.2.fill",
            iconTint: DS.Color.accent,
            title: "Speakers",
            onClose: { dismiss() },
            content: { contentBody },
            footer: { footerBody }
        )
        .task {
            suggestions = await model.peopleStore.suggestions(limit: 8)
        }
    }

    private var contentBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.medium) {
                if !transcript.uniqueSpeakers.isEmpty || !suggestions.isEmpty {
                    SearchPill(text: $searchText, placeholder: "Search speakers…")
                }
                if transcript.uniqueSpeakers.isEmpty {
                    Text("This transcript wasn't diarized — turn on Identify speakers in Settings before transcribing.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if filteredSpeakers.isEmpty && !transcript.uniqueSpeakers.isEmpty {
                    Text("No speakers match")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                }
                ForEach(filteredSpeakers, id: \.self) { speaker in
                    speakerRow(speaker)
                }
                if !filteredSuggestions.isEmpty {
                    Divider().padding(.vertical, 2)
                    Text("Recent")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                    FlowChips(items: filteredSuggestions.map(\.name)) { name in
                        applySuggestion(name)
                    }
                }
            }
            .padding(DS.Spacing.regular)
        }
    }

    private var filteredSpeakers: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return transcript.uniqueSpeakers }
        return transcript.uniqueSpeakers.filter { speaker in
            speaker.localizedCaseInsensitiveContains(query) ||
            (renames[speaker] ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredSuggestions: [Person] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return suggestions }
        return suggestions.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var footerBody: some View {
        HStack(spacing: DS.Spacing.small) {
            Button("Cancel") { dismiss() }
                .sheetSecondaryAction()
                .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Done") {
                model.applySpeakerRenames(renames)
                dismiss()
            }
            .sheetPrimaryAction()
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func speakerRow(_ speaker: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(speaker)
                .font(.body.weight(.medium))
                .foregroundStyle(DS.Color.secondaryText)
            TextField("Rename", text: renameBinding(for: speaker))
                .textFieldStyle(.roundedBorder)
                .focused($focusedSpeaker, equals: speaker)
        }
    }

    private func renameBinding(for speaker: String) -> Binding<String> {
        Binding(
            get: { renames[speaker] ?? speaker },
            set: { renames[speaker] = $0 }
        )
    }

    private var activeFieldKey: String? {
        if let focused = focusedSpeaker { return focused }
        return renames.keys.first(where: { speaker in
            (renames[speaker] ?? speaker) != speaker
        })
    }

    private func applySuggestion(_ name: String) {
        let target = activeFieldKey ?? transcript.uniqueSpeakers.first
        guard let target else { return }
        renames[target] = name
        focusedSpeaker = target
    }
}

private struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 60), spacing: 4)],
            alignment: .leading,
            spacing: 4
        ) {
            ForEach(items, id: \.self) { item in
                Button(item) { onTap(item) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}
