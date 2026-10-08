import SwiftUI
import ParolaCore

struct SendToPane: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ObsidianVaultFolderDestination?
    @State private var isNew = false
    @State private var selection: AnyDestination.ID?

    var body: some View {
        SettingsForm {
            Section {
                if model.destinations.isEmpty {
                    InlineEmptyText("No destinations yet")
                } else {
                    ForEach(Array(model.destinations.enumerated()), id: \.element.id) { position, stored in
                        DestinationRow(
                            stored: stored,
                            canMoveUp: position > 0,
                            canMoveDown: position < model.destinations.count - 1,
                            onEdit: { edit(stored) }
                        )
                        .ruleListRow(stored.id, selection: $selection, leaf: "SendTo.Row")
                    }
                }
                RuleListBar(
                    leafPrefix: "SendTo", addLabel: "Add Destination", removeLabel: "Remove Destination",
                    canRemove: model.destinations.contains { $0.id == selection },
                    addMenu: {
                        Button("Obsidian Vault Folder") {
                            isNew = true
                            editing = ObsidianVaultFolderDestination(
                                name: String(localized: "Obsidian"),
                                vaultBookmark: Data(),
                                vaultPath: ""
                            )
                        }
                        .accessibilityIdentifier("SendTo.Button.AddObsidian")
                    },
                    onRemove: removeSelected
                )
            }

            SettingHelper(text: "A destination writes a Markdown note when you send a transcript to it. Turn on Send automatically to write one as soon as a transcription finishes. A batch run is not sent automatically.")

            ResetPaneButton(scope: .sendTo)
        }
        .sheet(item: $editing) { destination in
            ObsidianDestinationEditor(
                destination: destination,
                isNew: isNew,
                onSave: { saved in
                    if isNew {
                        model.addDestination(.obsidianFolder(saved))
                    } else {
                        model.updateDestination(.obsidianFolder(saved))
                    }
                    editing = nil
                },
                onCancel: { editing = nil }
            )
            .environment(model)
        }
    }

    private func removeSelected() {
        guard let selection else { return }
        model.removeDestination(id: selection)
        self.selection = nil
    }

    private func edit(_ stored: AnyDestination) {
        guard case .obsidianFolder(let destination) = stored else { return }
        isNew = false
        editing = destination
    }
}

private struct DestinationRow: View {
    @Environment(AppModel.self) private var model
    let stored: AnyDestination
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if stored.destination != nil {
                controls
            }
        }
    }

    /// Every control in a row carries the destination id, so two rows never share an ax id.
    private func leaf(_ suffix: String) -> String {
        "SendTo.Row.\(stored.id.uuidString).\(suffix)"
    }

    private var header: some View {
        HStack(spacing: 8) {
            Toggle("Use this destination", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(stored.destination == nil)
                .axLeaf(leaf("Toggle.Enabled"))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: stored.name)
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.primaryText)
                Text(verbatim: subtitle)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if stored.destination != nil {
                Button {
                    model.moveDestination(id: stored.id, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveUp)
                .help("Move up")
                .axLeaf(leaf("Button.MoveUp"))
                Button {
                    model.moveDestination(id: stored.id, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveDown)
                .help("Move down")
                .axLeaf(leaf("Button.MoveDown"))
                Button("Edit…", action: onEdit)
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf(leaf("Button.Edit"))
            }
        }
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle(isOn: autoSendBinding) {
                Text("Send automatically")
                    .font(DS.Font.secondary)
            }
            .toggleStyle(.switch)
            .axLeaf(leaf("Toggle.AutoSend"))

            ForEach(EntryCategory.allCases, id: \.self) { category in
                CategoryChip(
                    category: category,
                    isSelected: stored.categories.contains(category),
                    leaf: leaf("Chip.Category.\(category.rawValue)"),
                    toggle: { toggle(category) }
                )
            }

            Spacer(minLength: 8)

            Picker("Note name", selection: titleFormatBinding) {
                ForEach(TitleFormat.allCases) { format in
                    Text(LocalizedStringKey(format.displayName)).tag(format)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 150, alignment: .trailing)
            .axLeaf(leaf("Picker.TitleFormat"))
        }
    }

    private var subtitle: String {
        guard case .obsidianFolder(let destination) = stored else {
            return String(localized: "Not supported in this version of Parola.")
        }
        let folder = destination.vaultPath.isEmpty
            ? String(localized: "No folder picked")
            : destination.vaultPath
        return destination.subfolder.isEmpty ? folder : "\(folder)/\(destination.subfolder)"
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { stored.isEnabled },
            set: { newValue in mutate { $0.isEnabled = newValue } }
        )
    }

    private var autoSendBinding: Binding<Bool> {
        Binding(
            get: { stored.autoSend },
            set: { newValue in mutate { $0.autoSend = newValue } }
        )
    }

    private var titleFormatBinding: Binding<TitleFormat> {
        Binding(
            get: { stored.titleFormat },
            set: { newValue in mutate { $0.titleFormat = newValue } }
        )
    }

    private func toggle(_ category: EntryCategory) {
        mutate { destination in
            if destination.categories.contains(category) {
                destination.categories.remove(category)
            } else {
                destination.categories.insert(category)
            }
        }
    }

    // Resolved by id on every write: the row's position can change under a move before the
    // toggle's write lands.
    private func mutate(_ change: (inout ObsidianVaultFolderDestination) -> Void) {
        guard case .obsidianFolder(var destination) = model.destination(id: stored.id) else { return }
        change(&destination)
        model.updateDestination(.obsidianFolder(destination))
    }
}

/// Its own view so the chip's ax id resolves against the pane's branch, the way every leaf does.
private struct CategoryChip: View {
    let category: EntryCategory
    let isSelected: Bool
    let leaf: String
    let toggle: () -> Void

    var body: some View {
        Chip(
            title: LocalizedStringKey(libraryCategoryName(category)),
            isSelected: isSelected,
            action: toggle
        )
        .axLeaf(leaf)
    }
}
