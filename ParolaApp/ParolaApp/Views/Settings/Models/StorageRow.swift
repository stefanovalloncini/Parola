import SwiftUI
import ParolaCore
import AppKit

struct StorageRow: View {
    @Environment(AppModel.self) private var model
    /// ModelStore reads its folder from UserDefaults.standard itself, not from the app's defaults suite.
    var defaults: UserDefaults = .standard
    var sharedOverrideFile: URL = ModelStore.sharedOverrideFileURL
    /// A launch with `--models=` keeps that folder across restarts, whatever is saved.
    var launchFolder: URL? = ModelStore.sharedDirectoryOverride
    @State private var overridePath: String?
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
                    .axLeaf("LocalModels.Button.RevealFolder")
                Button("Choose…") { chooseStorage() }
                if overridePath != nil {
                    Button("Use Default") { resetStorage() }
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
        .onAppear { overridePath = currentOverride() }
        .alert("Restart required", isPresented: $showingRestartAlert) {
            Button("OK") {}
        } message: {
            Text("Quit and relaunch Parola for the new models folder to take effect. Models already downloaded stay in the old folder.")
        }
    }

    private func currentOverride() -> String? {
        let custom = defaults.string(forKey: ModelStore.storageOverrideKey)?
            .trimmingCharacters(in: .whitespaces)
        return (custom?.isEmpty == false) ? custom : nil
    }

    /// The folder Parola moves to on its next launch, unless it's the one already in use.
    private var pendingPath: String? {
        guard launchFolder == nil else { return nil }
        let next = ModelStore.configuredDirectory(defaults: defaults, sharedOverrideFile: sharedOverrideFile)
        guard next.standardizedFileURL != ModelStore.shared.directory.standardizedFileURL else { return nil }
        return (next.path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseStorage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Choose models folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defaults.set(url.path, forKey: ModelStore.storageOverrideKey)
        ModelStore.writeSharedOverride(url.path, to: sharedOverrideFile)
        overridePath = currentOverride()
        showingRestartAlert = true
    }

    private func resetStorage() {
        defaults.removeObject(forKey: ModelStore.storageOverrideKey)
        ModelStore.writeSharedOverride(nil, to: sharedOverrideFile)
        overridePath = currentOverride()
        showingRestartAlert = true
    }
}
