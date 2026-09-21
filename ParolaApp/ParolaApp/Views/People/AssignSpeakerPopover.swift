import SwiftUI
import ParolaCore

/// Picks who a speaker label stands for. Every person in the directory is offered, most used
/// first, and a name that isn't there yet can be typed in.
struct AssignSpeakerPopover: View {
    let label: String
    let onRenameLabel: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newName: String = ""
    @FocusState private var nameFocused: Bool

    private var assigned: Person? { model.person(forSpeaker: label) }

    private var people: [Person] { model.mostUsedPeople(limit: 20) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if people.isEmpty {
                Text("No people yet — type a name below.")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .padding(.horizontal, DS.Spacing.regular)
                    .padding(.vertical, DS.Spacing.small)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(people) { person in
                            personRow(person)
                        }
                    }
                    .padding(.vertical, DS.Spacing.tight)
                }
                .frame(maxHeight: 220)
            }
            Divider()
            addField
            Divider()
            footer
        }
        .frame(width: 280)
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.small) {
            Circle()
                .fill(DS.speakerColor(for: label, colorIndex: assigned?.colorIndex))
                .frame(width: 8, height: 8)
            Text(verbatim: label)
                .font(DS.Font.bodyStrong)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
    }

    private func personRow(_ person: Person) -> some View {
        Button {
            Task { await model.assignSpeaker(label: label, to: person) }
            dismiss()
        } label: {
            HStack(spacing: DS.Spacing.small) {
                Image(systemName: person.id == assigned?.id ? "checkmark" : "circle.fill")
                    .font(DS.Font.caption)
                    .foregroundStyle(
                        person.id == assigned?.id
                            ? DS.Color.accentText
                            : DS.speakerColor(for: person.name, colorIndex: person.colorIndex)
                    )
                    .frame(width: 12)
                Text(verbatim: person.name)
                    .font(DS.Font.secondary)
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.small)
                Text(verbatim: "\(person.usageCount)")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.vertical, DS.Spacing.snug)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .axLeaf("Assign.Button.Person.\(person.name)")
    }

    private var addField: some View {
        TextField("Add a speaker…", text: $newName)
            .textFieldStyle(.plain)
            .focused($nameFocused)
            .fieldChrome(focused: nameFocused)
            .onSubmit { commit() }
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.vertical, DS.Spacing.small)
            .axLeaf("Assign.TextField.NewPerson")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            footerButton("Rename label…") {
                dismiss()
                onRenameLabel()
            }
            .axLeaf("Assign.Button.RenameLabel")
            footerButton("Clear speaker") {
                Task { await model.clearSpeaker(label: label) }
                dismiss()
            }
            .axLeaf("Assign.Button.ClearSpeaker")
        }
        .padding(.vertical, DS.Spacing.tight)
    }

    private func footerButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.Font.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.regular)
                .padding(.vertical, DS.Spacing.snug)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func commit() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await model.assignSpeaker(label: label, toNewPersonNamed: trimmed) }
        newName = ""
        dismiss()
    }
}
