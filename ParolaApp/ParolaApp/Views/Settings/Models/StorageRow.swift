import SwiftUI
import ParolaCore
import AppKit

struct StorageRow: View {
    @Environment(AppModel.self) private var model
    @State private var overridePath: String? = Self.currentOverride()
    @State private var pendingPath: String?
    @State private var showingRestartAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.hair) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(DS.Color.secondaryText)
                Text("Models folder:")
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.secondaryText)
                Text(verbatim: model.cacheDirectoryDisplayPath)
                    .font(DS.Font.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Reveal in Finder") { model.revealCacheDirectory() }
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf("LocalModels.Button.RevealFolder")
                Button("Choose…") { chooseStorage() }
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                if overridePath != nil {
                    Button("Use Default") { resetStorage() }
                        .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                }
            }
            if let pendingPath {
                Text("After a restart: \(pendingPath)")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.vertical, DS.Spacing.small)
        .onAppear { overridePath = Self.currentOverride() }
        .alert("Restart required", isPresented: $showingRestartAlert) {
            Button("OK") {}
        } message: {
            Text("Quit and relaunch Parola for the new models folder to take effect. Models already downloaded stay in the old folder.")
        }
    }

    // ModelStore reads this key from UserDefaults.standard itself, so this row matches it
    // instead of the app's defaults suite.
    private static func currentOverride() -> String? {
        let custom = UserDefaults.standard.string(forKey: ModelStore.storageOverrideKey)?
            .trimmingCharacters(in: .whitespaces)
        return (custom?.isEmpty == false) ? custom : nil
    }

    /// The folder Parola moves to on its next launch, unless it's the one already in use.
    private static func pending(_ folder: URL) -> String? {
        guard folder.standardizedFileURL != ModelStore.shared.directory.standardizedFileURL else { return nil }
        return (folder.path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseStorage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Choose models folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: ModelStore.storageOverrideKey)
        ModelStore.writeSharedOverride(url.path)
        overridePath = Self.currentOverride()
        pendingPath = Self.pending(url)
        showingRestartAlert = true
    }

    private func resetStorage() {
        UserDefaults.standard.removeObject(forKey: ModelStore.storageOverrideKey)
        ModelStore.writeSharedOverride(nil)
        overridePath = Self.currentOverride()
        pendingPath = Self.pending(ModelStore.defaultDirectory)
        showingRestartAlert = true
    }
}
