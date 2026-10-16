import SwiftUI
import ParolaCore

struct WatchedFoldersPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        WatchedFoldersPaneBody(store: model.watchedFolders)
    }
}

private struct WatchedFoldersPaneBody: View {
    @Environment(AppModel.self) private var model
    let store: WatchedFoldersStore
    @State private var selection: WatchedFolder.ID?

    var body: some View {
        SettingsForm {
            Section {
                if store.folders.isEmpty {
                    InlineEmptyText("No watched folders yet")
                } else {
                    RuleListRows(
                        store.folders, selection: $selection, leaf: "WatchedFolders.Row", label: \.displayName,
                        removeLabel: "Remove Folder", onRemove: remove
                    ) { folder in
                        WatchedFolderRow(store: store, folder: folder)
                    }
                }
                RuleListBar(
                    leafPrefix: "WatchedFolders", addLabel: "Add Folder…", removeLabel: "Remove Folder",
                    canRemove: store.folders.contains { $0.id == selection },
                    onAdd: { store.presentAddFolderPanel() },
                    onRemove: removeSelected
                )
            } footer: {
                if let error = store.lastError {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DS.Palette.warning)
                        Text(error)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Dismiss") { store.dismissError() }
                            .controlSize(.small)
                            .axLeaf("WatchedFolders.Button.DismissError")
                    }
                    .foregroundStyle(.secondary)
                }
            }

            SettingHelper(text: "New files added to a watched folder are transcribed automatically unless you turn that off in Options. That includes files added while Parola was closed. Files already there when you add the folder are ignored.")
            ResetPaneButton(scope: .watchedFolders)
        }
        .sheet(item: optionsFolder) { folder in
            WatchedFolderOptionsSheet(store: store, folder: folder) { store.optionsSheetFolderID = nil }
                .environment(model)
        }
    }

    private var optionsFolder: Binding<WatchedFolder?> {
        Binding(
            get: { store.optionsSheetFolderID.flatMap { id in store.folders.first { $0.id == id } } },
            set: { store.optionsSheetFolderID = $0?.id }
        )
    }

    private func removeSelected() {
        guard let selection else { return }
        remove(selection)
    }

    private func remove(_ id: WatchedFolder.ID) {
        store.removeFolder(id)
        if selection == id { selection = nil }
    }
}

private struct WatchedFolderRow: View {
    @Environment(AppModel.self) private var model
    let store: WatchedFoldersStore
    let folder: WatchedFolder

    var body: some View {
        let unavailable = store.isUnavailable(folder.id)
        SettingRow(titleVerbatim: folder.displayName, descriptionVerbatim: description) {
            HStack(spacing: 6) {
                if unavailable {
                    Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.warningText)
                    Button("Re-Add") {
                        store.reattach(folder.id)
                    }
                    .controlSize(.small)
                    .axLeaf("WatchedFolders.Button.Readd")
                }
                Button("Options…") {
                    store.optionsSheetFolderID = folder.id
                }
                .controlSize(.small)
                .axLeaf("WatchedFolders.Button.Options")
            }
        }
    }

    private var description: String {
        let path = (folder.displayPath as NSString).abbreviatingWithTildeInPath
        guard let summary = folder.options.summary(
            presets: model.exportPresets, batchIsEnabled: model.features.isEnabled(.batch)
        ) else { return path }
        return path + "\n" + summary
    }
}
