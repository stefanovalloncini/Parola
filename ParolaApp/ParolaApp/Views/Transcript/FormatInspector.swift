import SwiftUI

struct FormatInspector: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("transcriptDisplayMode") private var displayModeRaw: String = TranscriptDisplayMode.transcript.rawValue
    @AppStorage("transcriptFontSize") private var fontSize: Int = 18
    @AppStorage("transcriptFavoritesOnly") private var favoritesOnly: Bool = false
    @AppStorage("transcriptGroupUnnamed") private var groupUnnamed: Bool = false
    @State private var translateExpanded = false
    @State private var newSpeaker: String = ""

    private var displayMode: TranscriptDisplayMode {
        TranscriptDisplayMode(rawValue: displayModeRaw) ?? .transcript
    }

    var body: some View {
        VStack(spacing: DS.Spacing.medium) {
            copyButton

            displayModesCard

            InspectorGroup(title: "People") {
                TextField("Add a speaker…", text: $newSpeaker)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitSpeaker() }
            }

            InspectorDisclosureRow(title: "Translate to…", isExpanded: $translateExpanded) {
                Text("Translation runs as a separate pass.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }

            HStack {
                Text("Font Size")
                Spacer()
                Picker("Font Size", selection: $fontSize) {
                    ForEach([14, 16, 18, 20, 22, 24, 28], id: \.self) { size in
                        Text("\(size)").tag(size)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            Toggle("Favorites Only", isOn: $favoritesOnly)
                .toggleStyle(.switch)

            Toggle("Group segments without speakers", isOn: $groupUnnamed)
                .toggleStyle(.switch)
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
    }

    private var displayModesCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(spacing: DS.Spacing.small) {
                DisplayModeCard(
                    title: "Transcript",
                    icon: "text.alignleft",
                    isSelected: displayMode == .transcript
                ) { displayModeRaw = TranscriptDisplayMode.transcript.rawValue }

                DisplayModeCard(
                    title: "Segments",
                    icon: "list.bullet.below.rectangle",
                    isSelected: displayMode == .segments
                ) { displayModeRaw = TranscriptDisplayMode.segments.rawValue }
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
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: DS.Spacing.small) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
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
    }
}
