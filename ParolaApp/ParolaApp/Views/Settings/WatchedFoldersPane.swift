import SwiftUI
import ParolaCore

struct WatchedFoldersPane: View {
    @EnvironmentObject var model: AppModel

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
                    HStack {
                        Text("No watched folders yet.")
                            .foregroundStyle(.secondary)
                            .font(.body)
                        Spacer()
                    }
                    .padding(16)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss") { store.dismissError() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.Palette.warning.opacity(0.10))
                )
            }

            Button {
                store.presentAddFolderPanel()
            } label: {
                Label("Add Folder…", systemImage: "plus.circle")
            }

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
                        .font(.caption)
                        .foregroundStyle(DS.Palette.warning)
                    Button("Re-add") {
                        store.reattach(folder.id)
                    }
                    .controlSize(.small)
                }
                Button {
                    store.removeFolder(folder.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
