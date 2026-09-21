import SwiftUI
import ParolaCore

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
                ForEach(model.speakerSegmentCounts, id: \.label) { row in
                    SpeakerPersonRow(label: row.label, segmentCount: row.count)
                }
                TextField("Add a speaker…", text: $newSpeaker)
                    .textFieldStyle(.plain)
                    .focused($speakerFocused)
                    .fieldChrome(focused: speakerFocused)
                    .onSubmit { commitSpeaker() }
                    .axLeaf("Inspector.TextField.AddSpeaker")
                Button("Manage People…") { model.showingPeopleSheet = true }
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf("Inspector.Button.ManagePeople")
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
        Task { await model.addPerson(named: trimmed) }
        newSpeaker = ""
    }
}

/// What the row's pill says: naming the person again next to an identical label says nothing.
enum SpeakerPillState: Equatable {
    case unassigned
    case assigned
    case person(String)

    static func of(person: Person?, label: String) -> SpeakerPillState {
        guard let person else { return .unassigned }
        return person.name == label ? .assigned : .person(person.name)
    }
}

/// One speaker in this transcript: what it is called, how much of it there is, and who it is.
struct SpeakerPersonRow: View {
    let label: String
    let segmentCount: Int

    @Environment(AppModel.self) private var model

    private var person: Person? { model.person(forSpeaker: label) }

    @ViewBuilder
    private var pillLabel: some View {
        switch SpeakerPillState.of(person: person, label: label) {
        case .assigned: Label("Assigned", systemImage: "checkmark")
        case .person(let name): Text(verbatim: name)
        case .unassigned: Text("Unassigned")
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: label)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.speakerColor(for: label, colorIndex: person?.colorIndex))
                    .lineLimit(1)
                Text(verbatim: SegmentCount.label(segmentCount))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            Spacer(minLength: DS.Spacing.small)
            Menu {
                ForEach(model.mostUsedPeople(limit: 10)) { candidate in
                    Button(candidate.name) { Task { await model.assignSpeaker(label: label, to: candidate) } }
                        .axLeaf("Inspector.MenuItem.AssignPerson.\(candidate.name)")
                }
                if !model.people.isEmpty { Divider() }
                Button("Manage People…") { model.showingPeopleSheet = true }
                    .axLeaf("Inspector.MenuItem.ManagePeople")
                if person != nil {
                    Button("Clear speaker") { Task { await model.clearSpeaker(label: label) } }
                        .axLeaf("Inspector.MenuItem.ClearSpeaker")
                }
            } label: {
                pillLabel
                    .font(DS.Font.caption)
            }
            .menuStyle(.button)
            .buttonStyle(ChipButtonStyle(isSelected: person != nil))
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .axLeaf("Inspector.People.Row.\(label)")
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
