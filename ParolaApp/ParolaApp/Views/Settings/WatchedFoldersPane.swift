import SwiftUI
import ParolaCore

struct WatchedFoldersPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        WatchedFoldersPaneBody(store: model.watchedFolders)
    }
}

private struct WatchedFoldersPaneBody: View {
    let store: WatchedFoldersStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection {
                if store.folders.isEmpty {
                    InlineEmptyText("No watched folders yet")
                } else {
                    ForEach(Array(store.folders.enumerated()), id: \.element.id) { idx, folder in
                        WatchedFolderRow(store: store, folder: folder, isFirst: idx == 0)
                    }
                }
            }

            if let error = store.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DS.Palette.warning)
                    Text(error)
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss") { store.dismissError() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .axLeaf("WatchedFolders.Button.DismissError")
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                        .fill(DS.Palette.warning.opacity(0.10))
                )
            }

            Button {
                store.presentAddFolderPanel()
            } label: {
                Label("Add Folder…", systemImage: "plus.circle")
            }
            .axLeaf("WatchedFolders.Button.AddFolder")

            SettingHelper(text: "New files dropped into a watched folder are transcribed automatically. Existing files are ignored.")
            ResetPaneButton(scope: .watchedFolders)
        }
    }
}

private struct WatchedFolderRow: View {
    let store: WatchedFoldersStore
    let folder: WatchedFolder
    let isFirst: Bool

    var body: some View {
        let stale = store.isStale(folder.id)
        SettingRow(titleVerbatim: folder.displayName,
                   descriptionVerbatim: folder.displayPath,
                   isFirst: isFirst) {
            HStack(spacing: 6) {
                if stale {
                    Label("Stale", systemImage: "exclamationmark.triangle.fill")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.warningText)
                    Button("Re-add") {
                        store.reattach(folder.id)
                    }
                    .controlSize(.small)
                    .axLeaf("WatchedFolders.Button.Readd")
                }
                Button {
                    store.removeFolder(folder.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .axLeaf("WatchedFolders.Button.Remove")
            }
        }
    }
}
