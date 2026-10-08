import SwiftUI
import ParolaCore

struct ManagePeopleSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetFrame(
            title: "Manage People",
            onClose: { dismiss() },
            content: {
                ScrollView {
                    PeopleDirectoryList(takesRequests: true)
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
        .sheetSize(width: 460, minHeight: 300)
    }
}

/// The directory itself: add, rename, merge and delete. Shown in the sheet and in the People pane.
struct PeopleDirectoryList: View {
    /// Only the sheet asks what a sidebar person's menu wanted; the People pane in Settings leaves it.
    var takesRequests = false
    /// In a grouped form each person is a row of the form's own box, not a card inside it.
    var inForm = false
    @Environment(AppModel.self) private var model
    @State private var newName: String = ""
    @FocusState private var addFocused: Bool
    @State private var renaming: Person?
    @State private var renameDraft: String = ""
    @State private var deleting: Person?
    @State private var merging: MergePair?

    /// Who is folded into whom, while the confirmation is up.
    private struct MergePair: Identifiable {
        let source: Person
        let target: Person
        var id: UUID { source.id }
    }

    private var people: [Person] { model.peopleByUse }

    var body: some View {
        if inForm {
            formRows
        } else {
            stack
        }
    }

    @ViewBuilder private var formRows: some View {
        if people.isEmpty {
            InlineEmptyText("No people yet")
        } else {
            ForEach(people) { person in
                row(person)
            }
        }
        // The alerts hang off the one row that is always there.
        withAlerts(addRow)
    }

    private var stack: some View {
        withAlerts(
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                if people.isEmpty {
                    InlineEmptyText("No people yet")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(people.enumerated()), id: \.element.id) { position, person in
                            if position > 0 { Divider() }
                            row(person)
                                .padding(.horizontal, DS.Spacing.medium)
                                .padding(.vertical, DS.Spacing.small)
                        }
                    }
                    .cardBackground()
                }
                addRow
            }
            .onAppear { if takesRequests { takeRequest() } }
        )
    }

    private func withAlerts(_ content: some View) -> some View {
        content
        .alert("Rename person", isPresented: isRenaming, presenting: renaming) { person in
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renaming = nil }
                .axLeaf("People.Button.RenameCancel")
            Button("Rename") { commitRename(of: person) }
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .axLeaf("People.Button.RenameConfirm")
        } message: { _ in
            Text("The new name replaces the old one in every transcript. That rewrite can't be undone.")
        }
        .alert("Merge people", isPresented: isMerging, presenting: merging) { pair in
            Button("Cancel", role: .cancel) { merging = nil }
                .axLeaf("People.Button.MergeCancel")
            Button("Merge") {
                Task { await model.mergePerson(pair.source.id, into: pair.target.id) }
                merging = nil
            }
            .axLeaf("People.Button.MergeConfirm")
        } message: { pair in
            Text("\(pair.source.name) is folded into \(pair.target.name), and the transcripts that named them take the new name. That rewrite can't be undone.")
        }
        .alert("Delete person", isPresented: isDeleting, presenting: deleting) { person in
            Button("Cancel", role: .cancel) { deleting = nil }
                .axLeaf("People.Button.DeleteCancel")
            Button("Delete", role: .destructive) {
                Task { await model.deletePerson(person.id) }
                deleting = nil
            }
            .axLeaf("People.Button.DeleteConfirm")
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
            Text(verbatim: SegmentCount.assignments(model.usageCount(of: person)))
                .font(DS.Font.caption)
                .monospacedDigit()
                .foregroundStyle(DS.Color.secondaryText)
            Menu {
                Button("Rename…") {
                    renameDraft = person.name
                    renaming = person
                }
                .axLeaf("People.MenuItem.Rename.\(person.name)")
                Menu("Merge Into") {
                    ForEach(people.filter { $0.id != person.id }) { target in
                        Button(target.name) { merging = MergePair(source: person, target: target) }
                            .axLeaf("People.MenuItem.MergeInto.\(target.name)")
                    }
                }
                .disabled(people.count < 2)
                Toggle("This Is Me", isOn: isMe(person))
                    .axLeaf("People.MenuItem.ThisIsMe.\(person.name)")
                Divider()
                Button("Delete", role: .destructive) { deleting = person }
                    .axLeaf("People.MenuItem.Delete.\(person.name)")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
            .axLeaf("People.Menu.Row.\(person.name)")
        }
    }

    private var addRow: some View {
        HStack(spacing: DS.Spacing.small) {
            addField
                .onSubmit { add() }
                .axLeaf("People.TextField.Add")
            Button("Add") { add() }
                .sheetButton()
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .axLeaf("People.Button.Add")
        }
    }

    @ViewBuilder private var addField: some View {
        if inForm {
            TextField("Add a person…", text: $newName, prompt: Text("Add a person…"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        } else {
            TextField("Add a person…", text: $newName)
                .textFieldStyle(.plain)
                .focused($addFocused)
                .fieldChrome(focused: addFocused)
        }
    }

    /// A rename onto a name the directory already holds folds the two people together, so it asks
    /// with the Merge wording instead of promising a plain rename.
    private func commitRename(of person: Person) {
        let draft = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !draft.isEmpty else { return }
        if let existing = model.person(named: draft), existing.id != person.id {
            // Next turn: a second alert raised while the first is still dismissing is dropped.
            Task { @MainActor in merging = MergePair(source: person, target: existing) }
            return
        }
        Task { await model.renamePerson(person.id, to: draft) }
    }

    private func takeRequest() {
        guard let request = model.peopleSheetRequest else { return }
        model.peopleSheetRequest = nil
        switch request {
        case .rename(let id):
            guard let person = model.person(id: id) else { return }
            renameDraft = person.name
            renaming = person
        case .delete(let id):
            deleting = model.person(id: id)
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

    private var isMerging: Binding<Bool> {
        Binding(get: { merging != nil }, set: { if !$0 { merging = nil } })
    }

    /// Your side of a meeting takes this person's name.
    private func isMe(_ person: Person) -> Binding<Bool> {
        Binding(get: { person.isMe }, set: { isMe in Task { await model.setMePerson(isMe ? person.id : nil) } })
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
}
