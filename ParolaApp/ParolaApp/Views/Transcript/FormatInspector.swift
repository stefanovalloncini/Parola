import SwiftUI

struct FormatInspector: View {
    @Environment(AppModel.self) private var model
    @State private var newSpeaker: String = ""
    @FocusState private var speakerFocused: Bool

    private var displayMode: TranscriptDisplayMode {
        model.transcriptDisplayMode
    }

    var body: some View {
        VStack(spacing: DS.Spacing.medium) {
            displayModesSection

            TranslationSection()

            InspectorSection(title: "People") {
                TextField("Add a speaker…", text: $newSpeaker)
                    .textFieldStyle(.plain)
                    .focused($speakerFocused)
                    .fieldChrome(focused: speakerFocused)
                    .onSubmit { commitSpeaker() }
                    .axLeaf("Inspector.TextField.AddSpeaker")
            }
        }
    }

    private var displayModesSection: some View {
        @Bindable var model = model
        return InspectorSection(title: "Display Modes") {
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

            if displayMode == .segments {
                Toggle(isOn: $model.showSubtitleQC) {
                    Text("Subtitle QC")
                }
                .help("Warn about segments that read too fast or fall outside caption limits.")
                .accessibilityIdentifier("toolbar.subtitleQC")
                .axLeaf("Inspector.Toggle.SubtitleQC")
            }

            Toggle(isOn: $model.favoritesOnly) {
                Text(String(localized: "Favorites only (\(model.favoriteSegmentIDs.count))"))
            }
            .disabled(!model.favoritesOnly && model.favoriteSegmentIDs.isEmpty)
            .axLeaf("Format.Toggle.FavoritesOnly")
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
                    .font(DS.Font.title)
                Text(title).font(DS.Font.secondary)
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
