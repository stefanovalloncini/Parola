import SwiftUI
import ParolaCore

/// Who spoke. A row only asks for something when its speaker isn't anyone yet.
struct OverviewPeople: View {
    @Environment(AppModel.self) private var model
    @State private var speakerRows: [(label: String, count: Int)] = []

    var body: some View {
        OverviewSection(title: Text("People"), menu: SectionMenu(label: "People Options", leaf: "Inspector.Menu.People")) {
            VStack(alignment: .leading, spacing: DS.Spacing.tight) {
                ForEach(speakerRows, id: \.label) { row in
                    SpeakerPersonRow(label: row.label, segmentCount: row.count)
                }
            }
        } actions: {
            PeopleActions()
        }
        // Counting walks every segment; the body re-runs on the favourites toggle and on translation
        // progress, neither of which can change the count.
        .task(id: model.transcriptVersion) { speakerRows = model.speakerSegmentCounts }
    }
}

/// The People ⋯ menu: the two sheets that rename labels and look after the directory.
struct PeopleActions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Rename Speakers…") { model.showingSpeakersSheet = true }
            .axLeaf("Inspector.Button.RenameSpeakers")
        Button("Manage People…") { model.showingPeopleSheet = true }
            .axLeaf("Inspector.Button.ManagePeople")
    }
}

/// What a speaker row adds after the label: naming the person again next to an identical label says nothing.
enum SpeakerRowState: Equatable {
    case unassigned
    case assigned
    case person(String)

    static func of(person: Person?, label: String) -> SpeakerRowState {
        guard let person else { return .unassigned }
        return person.name == label ? .assigned : .person(person.name)
    }
}

/// One speaker in this transcript: its colour, its name and how much of it there is. An assigned row opens the same menu on click.
struct SpeakerPersonRow: View {
    let label: String
    let segmentCount: Int

    @Environment(AppModel.self) private var model
    @State private var naming = false
    @State private var draftName = ""
    @State private var hovering = false

    private var person: Person? { model.person(forSpeaker: label) }
    private var state: SpeakerRowState { SpeakerRowState.of(person: person, label: label) }

    var body: some View {
        Group {
            if state == .unassigned {
                identity {
                    Menu { choices } label: {
                        Text("Assign…")
                            .font(DS.Font.secondary)
                            .foregroundStyle(DS.Color.accentInk)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .layoutPriority(1)
                    .accessibilityLabel(Text("Assign \(label)…"))
                    .axLeaf("Inspector.Menu.Assign")
                }
            } else {
                Menu { choices } label: {
                    identity { EmptyView() }
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                        .fill(hovering ? DS.Palette.surfaceHover : .clear)
                        .padding(.horizontal, -DS.Spacing.tight)
                )
                .onHover { hovering = $0 }
                .accessibilityLabel(Text(verbatim: spokenName))
                .axLeaf("Inspector.Menu.Person")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .axLeaf("Inspector.People.Row.\(label)")
        .alert("Assign speaker", isPresented: $naming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Assign") { Task { await model.assignSpeaker(label: label, toNewPersonNamed: draftName) } }
        }
    }

    /// The label, the person when the label doesn't already say it, and the count in words.
    private var spokenName: String {
        var parts = [label]
        if case .person(let name) = state { parts.append(name) }
        parts.append(SegmentCount.label(segmentCount))
        return parts.joined(separator: ", ")
    }

    /// The count stays at the trailing edge on every row, so `accessory` goes between the name and it.
    private func identity<Accessory: View>(@ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: DS.Spacing.small) {
            Circle()
                .fill(model.speakerColor(for: label))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(verbatim: label)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.primaryText)
                .lineLimit(1)
            if case .person(let name) = state {
                Text(verbatim: name)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Spacing.small)
            accessory()
            Text(verbatim: AppFormat.integer(segmentCount))
                .font(DS.Font.secondary)
                .monospacedDigit()
                .foregroundStyle(DS.Color.secondaryText)
                .help(Text(verbatim: SegmentCount.label(segmentCount)))
                .accessibilityLabel(Text(verbatim: SegmentCount.label(segmentCount)))
        }
        .padding(.vertical, DS.Spacing.hair)
    }

    @ViewBuilder
    private var choices: some View {
        let choices = model.personMenuChoices(limit: 10)
        ForEach(choices.top) { candidate in
            Button(candidate.name) { Task { await model.assignSpeaker(label: label, to: candidate) } }
                .axLeaf("Inspector.MenuItem.AssignPerson.\(candidate.name)")
        }
        MorePeopleMenu(people: choices.more) { candidate in
            Task { await model.assignSpeaker(label: label, to: candidate) }
        }
        Button("New Person…") {
            draftName = ""
            naming = true
        }
        .axLeaf("Inspector.MenuItem.NewPerson")
        Divider()
        Button("Manage People…") { model.showingPeopleSheet = true }
            .axLeaf("Inspector.MenuItem.ManagePeople")
        if let person {
            Button("Unassign \(person.name)") { Task { await model.unassignSpeaker(label: label) } }
                .axLeaf("Inspector.MenuItem.UnassignPerson")
            Button("No Speaker") { Task { await model.clearSpeaker(label: label) } }
                .axLeaf("Inspector.MenuItem.ClearSpeaker")
        }
    }
}
