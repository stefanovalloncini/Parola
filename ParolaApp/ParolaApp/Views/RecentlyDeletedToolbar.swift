import SwiftUI
import ParolaCore

struct RecentlyDeletedToolbar: View {
    @EnvironmentObject var model: AppModel
    @Binding var searchText: String
    @Binding var confirmingEmpty: Bool
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            Text("Recently Deleted")
                .font(.system(.title2, design: .default, weight: .semibold))
            Spacer(minLength: DS.Spacing.regular)
            searchField
            actionMenu
            emptyTrashButton
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
    }

    var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .frame(minWidth: 140, maxWidth: 200)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RecentlyDeletedPillChrome())
    }

    var actionMenu: some View {
        Menu {
            Button("Restore All") {
                for entry in model.deletedEntries { model.restoreEntry(entry.id) }
            }
            .disabled(model.deletedEntries.isEmpty)
            Divider()
            Button("Empty Recently Deleted", role: .destructive) {
                confirmingEmpty = true
            }
            .disabled(model.deletedEntries.isEmpty)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 26)
                .background(RecentlyDeletedPillChrome())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    var emptyTrashButton: some View {
        Button { confirmingEmpty = true } label: {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 26)
                .background(RecentlyDeletedPillChrome())
        }
        .buttonStyle(.plain)
        .disabled(model.deletedEntries.isEmpty)
        .help("Empty Recently Deleted")
    }
}

struct RecentlyDeletedPillChrome: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(DS.Color.surfaceElevated.opacity(0.85))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(DS.Color.separator.opacity(0.4), lineWidth: 0.5)
            )
    }
}
