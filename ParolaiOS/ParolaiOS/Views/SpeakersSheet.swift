import SwiftUI
import ParolaCore

struct SpeakersSheet: View {
    let entryID: LibraryEntry.ID
    let transcript: Transcript
    let onApply: (Transcript) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var renames: [String: String] = [:]
    @State private var suggestions: [Person] = []
    @State private var isApplying: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if transcript.uniqueSpeakers.isEmpty {
                        Text("This transcript wasn't diarized — turn on Identify speakers in Settings before transcribing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(transcript.uniqueSpeakers, id: \.self) { speaker in
                            speakerRow(speaker)
                        }
                    }
                } header: {
                    Text("Speakers in this transcript")
                }
                if !suggestions.isEmpty {
                    Section {
                        FlowChips(items: suggestions.map(\.name)) { name in
                            applySuggestion(name)
                        }
                    } header: {
                        Text("Recent")
                    }
                }
            }
            .navigationTitle("Speakers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") {
                        apply()
                    }
                    .disabled(isApplying || renames.isEmpty)
                }
            }
        }
        .task {
            suggestions = await model.peopleStore.suggestions(limit: 8)
        }
    }

    @ViewBuilder
    private func speakerRow(_ speaker: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(speaker)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Rename", text: Binding(
                get: { renames[speaker] ?? speaker },
                set: { renames[speaker] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.words)
        }
    }

    private var firstActiveKey: String? {
        renames.keys.first(where: { (renames[$0] ?? $0) != $0 })
    }

    private func applySuggestion(_ name: String) {
        let target = firstActiveKey ?? transcript.uniqueSpeakers.first
        guard let target else { return }
        renames[target] = name
    }

    private func apply() {
        isApplying = true
        Task {
            let updated = await model.applySpeakerRenames(renames, on: transcript, entryID: entryID)
            onApply(updated)
            dismiss()
        }
    }
}

private struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 70), spacing: 4)],
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
