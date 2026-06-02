import SwiftUI

struct FormatInspector: View {
    @Environment(AppModel.self) private var model
    @State private var newSpeaker: String = ""

    private var displayMode: TranscriptDisplayMode {
        model.transcriptDisplayMode
    }

    var body: some View {
        VStack(spacing: DS.Spacing.medium) {
            copyButton

            displayModesCard

            InspectorGroup(title: "People") {
                TextField("Add a speaker…", text: $newSpeaker)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitSpeaker() }
                    .axLeaf("Inspector.TextField.AddSpeaker")
            }
        }
    }

    private var copyButton: some View {
        Button {
            guard let t = model.transcript else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(t.text, forType: .string)
        } label: {
            HStack(spacing: DS.Spacing.small) {
                Image(systemName: "doc.on.doc")
                Text("Copy")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.small)
            .background(
                Capsule(style: .continuous)
                    .fill(DS.Color.surfaceElevated)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.transcript == nil)
        .axLeaf("Inspector.Button.CopyTranscript")
    }

    private var displayModesCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(spacing: DS.Spacing.small) {
                DisplayModeCard(
                    title: "Transcript",
                    icon: "text.alignleft",
                    isSelected: displayMode == .transcript
                ) { model.transcriptDisplayMode = .transcript }

                DisplayModeCard(
                    title: "Segments",
                    icon: "list.bullet.below.rectangle",
                    isSelected: displayMode == .segments
                ) { model.transcriptDisplayMode = .segments }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Display Modes")
                    .font(DS.Font.heading)
                Text("Toggle between transcript and segment layouts.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            .padding(DS.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Color.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.regular))
        }
    }

    private func commitSpeaker() {
        let trimmed = newSpeaker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { [peopleStore = model.peopleStore] in
            _ = await peopleStore.recordUsage(name: trimmed)
        }
        newSpeaker = ""
    }
}

struct DisplayModeCard: View {
    let title: LocalizedStringKey
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: DS.Spacing.small) {
                Image(systemName: icon)
                    .font(DS.Font.titleRegular)
                Text(title).font(DS.Font.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.medium)
            .background(DS.Color.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.regular)
                    .strokeBorder(isSelected ? DS.Color.accent : Color.clear, lineWidth: 2)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.regular))
        }
        .buttonStyle(.plain)
        .axLeaf("Inspector.Button.DisplayMode.\(icon.replacingOccurrences(of: ".", with: ""))")
    }
}
