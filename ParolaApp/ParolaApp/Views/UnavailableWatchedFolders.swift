import SwiftUI
import ParolaCore

/// A watched folder Parola can't reach stops the watch; the sidebar says so and offers to find it again.
struct UnavailableWatchedFolders: View {
    let store: WatchedFoldersStore

    var body: some View {
        let folders = store.unavailableFolders
        if !folders.isEmpty {
            Section("Watched Folders") {
                ForEach(folders) { folder in
                    UnavailableWatchedFolderRow(folder: folder) {
                        store.reattach(folder.id)
                    }
                }
                .axBranch("WatchedFolders")
            }
        }
    }
}

private struct UnavailableWatchedFolderRow: View {
    let folder: WatchedFolder
    let locate: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Palette.warning)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: folder.displayName)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Unavailable")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warningText)
            }
            Spacer(minLength: 0)
            Button("Locate…", action: locate)
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .axLeaf("Button.Locate")
        }
        .padding(.vertical, DS.Spacing.hair)
        .help(folder.displayPath)
    }
}
