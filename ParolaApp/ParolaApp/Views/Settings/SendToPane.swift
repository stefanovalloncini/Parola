import SwiftUI
import ParolaCore

private enum DestinationDraft: Identifiable {
    case folder(ObsidianVaultFolderDestination)
    case rest(ObsidianLocalRESTDestination)
    case webhook(WebhookDestination)
    case notion(NotionDestination)

    var id: UUID {
        switch self {
        case .folder(let value): return value.id
        case .rest(let value): return value.id
        case .webhook(let value): return value.id
        case .notion(let value): return value.id
        }
    }

    var stored: AnyDestination {
        switch self {
        case .folder(let value): return .obsidianFolder(value)
        case .rest(let value): return .obsidianREST(value)
        case .webhook(let value): return .webhook(value)
        case .notion(let value): return .notion(value)
        }
    }

    init?(_ stored: AnyDestination) {
        switch stored {
        case .obsidianFolder(let value): self = .folder(value)
        case .obsidianREST(let value): self = .rest(value)
        case .webhook(let value): self = .webhook(value)
        case .notion(let value): self = .notion(value)
        case .mock, .unsupported: return nil
        }
    }
}

struct SendToPane: View {
    @Environment(AppModel.self) private var model
    @State private var editing: DestinationDraft?
    @State private var isNew = false
    @State private var selection: AnyDestination.ID?

    var body: some View {
        SettingsForm {
            Section {
                if model.destinations.isEmpty {
                    InlineEmptyText("No destinations yet")
                } else {
                    RuleListRows(
                        model.destinations, selection: $selection, leaf: "SendTo.Row", label: \.name,
                        removeLabel: "Remove Destination", onRemove: remove
                    ) { stored in
                        let position = model.destinations.firstIndex { $0.id == stored.id } ?? 0
                        DestinationRow(
                            stored: stored,
                            canMoveUp: position > 0,
                            canMoveDown: position < model.destinations.count - 1,
                            onEdit: { edit(stored) }
                        )
                    }
                }
                RuleListBar(
                    leafPrefix: "SendTo", addLabel: "Add Destination", removeLabel: "Remove Destination",
                    canRemove: model.destinations.contains { $0.id == selection },
                    addMenu: {
                        addButton(
                            "Obsidian Vault Folder", line: "Writes a note into a vault folder on this Mac.",
                            leaf: "SendTo.Button.AddObsidian", kind: .obsidianFolder
                        )
                        addButton(
                            "Obsidian Local REST", line: "Sends a note to an open vault through the plugin.",
                            leaf: "SendTo.Button.AddObsidianREST", kind: .obsidianREST
                        )
                        addButton(
                            "Webhook", line: "Posts JSON to Zapier, Make, n8n or your own server.",
                            leaf: "SendTo.Button.AddWebhook", kind: .webhook
                        )
                        addButton(
                            "Notion", line: "Adds a page under a Notion page you choose.",
                            leaf: "SendTo.Button.AddNotion", kind: .notion
                        )
                    },
                    onRemove: removeSelected
                )
            }

            SettingHelper(text: "A destination receives the transcript when you send it: a Markdown note, a page or a JSON post. Turn on Send automatically to send as soon as a transcription finishes. A batch run is not sent automatically.")

            ResetPaneButton(scope: .sendTo)
        }
        .onChange(of: model.destinationEditorRequest, initial: true) { _, request in
            guard let request else { return }
            model.destinationEditorRequest = nil
            open(request.target)
        }
        .sheet(item: $editing) { draft in
            editor(for: draft)
                .environment(model)
        }
    }

    @ViewBuilder
    private func editor(for draft: DestinationDraft) -> some View {
        switch draft {
        case .folder(let value):
            ObsidianDestinationEditor(
                destination: value, isNew: isNew,
                onSave: { commit(.obsidianFolder($0)) }, onCancel: { editing = nil }
            )
        case .rest(let value):
            ObsidianRESTDestinationEditor(
                destination: value, isNew: isNew,
                onSave: { commit(.obsidianREST($0)) }, onCancel: { editing = nil }
            )
        case .webhook(let value):
            WebhookDestinationEditor(
                destination: value, isNew: isNew,
                onSave: { commit(.webhook($0)) }, onCancel: { editing = nil }
            )
        case .notion(let value):
            NotionDestinationEditor(
                destination: value, isNew: isNew,
                onSave: { commit(.notion($0)) }, onCancel: { editing = nil }
            )
        }
    }

    private func addButton(_ title: LocalizedStringKey, line: LocalizedStringKey, leaf: String, kind: DestinationKind) -> some View {
        Button {
            open(.new(kind))
        } label: {
            Text(title)
            Text(line)
        }
        .help(line)
        .axLeaf(leaf)
    }

    private func open(_ target: DestinationEditorRequest.Target) {
        switch target {
        case .new(let kind):
            isNew = true
            editing = Self.blank(kind)
        case .existing(let id):
            guard let stored = model.destination(id: id), let draft = DestinationDraft(stored) else { return }
            isNew = false
            editing = draft
        }
    }

    private static func blank(_ kind: DestinationKind) -> DestinationDraft {
        switch kind {
        case .obsidianFolder:
            return .folder(ObsidianVaultFolderDestination(name: String(localized: "Obsidian"), vaultBookmark: Data(), vaultPath: ""))
        case .obsidianREST: return .rest(ObsidianLocalRESTDestination(name: String(localized: "Obsidian REST")))
        case .webhook: return .webhook(WebhookDestination(name: String(localized: "Webhook")))
        case .notion: return .notion(NotionDestination(name: String(localized: "Notion")))
        }
    }

    private func commit(_ saved: AnyDestination) {
        if isNew {
            model.addDestination(saved)
        } else {
            model.updateDestination(saved)
        }
        editing = nil
    }

    private func removeSelected() {
        guard let selection else { return }
        remove(selection)
    }

    private func remove(_ id: AnyDestination.ID) {
        model.removeDestination(id: id)
        if selection == id { selection = nil }
    }

    private func edit(_ stored: AnyDestination) {
        guard let draft = DestinationDraft(stored) else { return }
        isNew = false
        editing = draft
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
                CategoryToggle(
                    category: category,
                    isSelected: stored.categories.contains(category),
                    leaf: leaf("Chip.Category.\(category.rawValue)"),
                    toggle: { toggle(category) }
                )
            }

            Spacer(minLength: 8)

            if stored.kind != .webhook {
                Picker("Note name", selection: titleFormatBinding) {
                    ForEach(TitleFormat.allCases) { format in
                        Text(LocalizedStringKey(format.displayName)).tag(format)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150, alignment: .trailing)
                .axLeaf(leaf("Picker.TitleFormat"))
            } else {
                Color.clear.frame(width: 150, height: 1)
            }
        }
    }

    private var subtitle: String {
        guard let kind = stored.kind, stored.destination != nil else {
            return String(localized: "Not supported in this version of Parola.")
        }
        return detail.isEmpty ? kind.localizedName : "\(kind.localizedName) · \(detail)"
    }

    private var detail: String {
        switch stored {
        case .obsidianFolder(let destination):
            let folder = destination.vaultPath.isEmpty
                ? String(localized: "No folder picked")
                : destination.vaultPath
            return destination.subfolder.isEmpty ? folder : "\(folder)/\(destination.subfolder)"
        case .obsidianREST(let destination):
            let host = URL(string: destination.baseURLText)?.host ?? destination.baseURLText
            return destination.folder.isEmpty ? host : "\(host)/\(destination.folder)"
        case .webhook(let destination):
            return URL(string: destination.urlText)?.host ?? String(localized: "No address")
        case .notion(let destination):
            return destination.parentPageID.isEmpty
                ? String(localized: "No page")
                : String(localized: "Page ending \(String(destination.parentPageID.suffix(6)))")
        case .mock, .unsupported:
            return ""
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { stored.isEnabled },
            set: { newValue in mutate { $0.updating(isEnabled: newValue) } }
        )
    }

    private var autoSendBinding: Binding<Bool> {
        Binding(
            get: { stored.autoSend },
            set: { newValue in mutate { $0.updating(autoSend: newValue) } }
        )
    }

    private var titleFormatBinding: Binding<TitleFormat> {
        Binding(
            get: { stored.titleFormat },
            set: { newValue in mutate { $0.updating(titleFormat: newValue) } }
        )
    }

    private func toggle(_ category: EntryCategory) {
        mutate { destination in
            var categories = destination.categories
            if categories.contains(category) {
                categories.remove(category)
            } else {
                categories.insert(category)
            }
            return destination.updating(categories: categories)
        }
    }

    // Resolved by id on every write: the row's position can change under a move before the
    // toggle's write lands.
    private func mutate(_ change: (AnyDestination) -> AnyDestination) {
        guard let current = model.destination(id: stored.id) else { return }
        model.updateDestination(change(current))
    }
}

/// Its own view so the toggle's ax id resolves against the pane's branch, the way every leaf does.
private struct CategoryToggle: View {
    let category: EntryCategory
    let isSelected: Bool
    let leaf: String
    let toggle: () -> Void

    var body: some View {
        Toggle(LocalizedStringKey(libraryCategoryName(category)), isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
            .toggleStyle(.button)
            .axLeaf(leaf)
    }
}
