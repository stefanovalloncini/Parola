import SwiftUI
import ParolaCore

struct SpeakersSheet: View {
    let transcript: Transcript
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var renames: [String: String] = [:]
    @State private var suggestions: [Person] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Speakers").font(DS.Font.heading)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") {
                    model.applySpeakerRenames(renames)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Spacing.regular)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.medium) {
                    if transcript.uniqueSpeakers.isEmpty {
                        Text("This transcript wasn't diarized — turn on Identify speakers in Settings before transcribing.")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                    ForEach(transcript.uniqueSpeakers, id: \.self) { speaker in
                        speakerRow(speaker)
                    }
                    if !suggestions.isEmpty {
                        Divider()
                        Text("Recent")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.secondaryText)
                        FlowChips(items: suggestions.map(\.name)) { name in
                            applySuggestion(name)
                        }
                    }
                }
                .padding(DS.Spacing.regular)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .task {
            suggestions = await model.peopleStore.suggestions(limit: 8)
        }
    }

    @ViewBuilder
    private func speakerRow(_ speaker: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(speaker)
                .font(.body.weight(.medium))
                .foregroundStyle(DS.Color.secondaryText)
            TextField("Rename", text: Binding(
                get: { renames[speaker] ?? speaker },
                set: { renames[speaker] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
        }
    }

    private var activeFieldKey: String? {
        renames.keys.first(where: { speaker in
            (renames[speaker] ?? speaker) != speaker
        })
    }

    private func applySuggestion(_ name: String) {
        let target = activeFieldKey ?? transcript.uniqueSpeakers.first
        guard let target else { return }
        renames[target] = name
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
