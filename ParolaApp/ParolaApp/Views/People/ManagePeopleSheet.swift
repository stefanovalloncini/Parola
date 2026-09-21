import SwiftUI
import ParolaCore

struct ManagePeopleSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetFrame(
            icon: "person.2.fill",
            iconTint: DS.Color.accent,
            title: "Manage People",
            onClose: { dismiss() },
            content: {
                ScrollView {
                    PeopleDirectoryList()
                        .padding(DS.Spacing.regular)
                }
            },
            footer: {
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .sheetPrimaryAction()
                        .keyboardShortcut(.defaultAction)
                        .axLeaf("People.Button.Done")
                }
            }
        )
        .hidesCloseButton()
        .sheetSize(width: 460, minHeight: 300)
    }
}

/// The directory itself: add, rename, merge and delete. Shown in the sheet and in the People pane.
struct PeopleDirectoryList: View {
    @Environment(AppModel.self) private var model
    @State private var newName: String = ""
    @FocusState private var addFocused: Bool
    @State private var renaming: Person?
    @State private var renameDraft: String = ""
    @State private var deleting: Person?

    private var people: [Person] { model.mostUsedPeople(limit: 200) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            if people.isEmpty {
                InlineEmptyText("No people yet")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(people.enumerated()), id: \.element.id) { position, person in
                        if position > 0 { Divider() }
                        row(person)
                    }
                }
                .cardBackground()
            }
            addRow
        }
        .alert("Rename person", isPresented: isRenaming, presenting: renaming) { person in
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                let draft = renameDraft
                Task { await model.renamePerson(person.id, to: draft) }
                renaming = nil
            }
        } message: { _ in
            Text("The new name replaces the old one in every transcript. That rewrite can't be undone.")
        }
        .alert("Delete person", isPresented: isDeleting, presenting: deleting) { person in
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                Task { await model.deletePerson(person.id) }
                deleting = nil
            }
        } message: { person in
            Text("\(person.name) is forgotten and the transcripts stop pointing at them. The names already written into them stay, and that can't be undone.")
        }
    }

    private func row(_ person: Person) -> some View {
        HStack(spacing: DS.Spacing.small) {
            Circle()
                .fill(DS.speakerColor(for: person.name, colorIndex: person.colorIndex))
                .frame(width: 8, height: 8)
            Text(verbatim: person.name)
                .font(DS.Font.body)
                .lineLimit(1)
            Spacer(minLength: DS.Spacing.small)
            Text(verbatim: SegmentCount.assignments(person.usageCount))
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
            Menu {
                Button("Rename…") {
                    renameDraft = person.name
                    renaming = person
                }
                .axLeaf("People.MenuItem.Rename.\(person.name)")
                Menu("Merge Into") {
                    ForEach(people.filter { $0.id != person.id }) { target in
                        Button(target.name) { Task { await model.mergePerson(person.id, into: target.id) } }
                            .axLeaf("People.MenuItem.MergeInto.\(target.name)")
                    }
                }
                .disabled(people.count < 2)
                Divider()
                Button("Delete", role: .destructive) { deleting = person }
                    .axLeaf("People.MenuItem.Delete.\(person.name)")
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(DSIconChipButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .axLeaf("People.Menu.Row.\(person.name)")
        }
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.vertical, DS.Spacing.small)
    }

    private var addRow: some View {
        HStack(spacing: DS.Spacing.small) {
            TextField("Add a person…", text: $newName)
                .textFieldStyle(.plain)
                .focused($addFocused)
                .fieldChrome(focused: addFocused)
                .onSubmit { add() }
                .axLeaf("People.TextField.Add")
            Button("Add") { add() }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .axLeaf("People.Button.Add")
        }
    }

    private func add() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await model.addPerson(named: trimmed) }
        newName = ""
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
}
