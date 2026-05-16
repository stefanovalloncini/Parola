import SwiftUI
import ParolaCore

struct WatchedFoldersPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection {
                if model.watchedFolders.folders.isEmpty {
                    HStack {
                        Text("No watched folders yet.")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ForEach(Array(model.watchedFolders.folders.enumerated()), id: \.element.id) { idx, folder in
                        SettingRow(folder.displayName,
                                   description: folder.displayPath,
                                   isFirst: idx == 0) {
                            Button {
                                model.watchedFolders.removeFolder(folder.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Button {
                model.watchedFolders.presentAddFolderPanel()
            } label: {
                Label("Add Folder…", systemImage: "plus.circle")
            }

            SettingHelper(text: "New files dropped into a watched folder are transcribed automatically. Existing files are ignored.")
        }
    }
}
