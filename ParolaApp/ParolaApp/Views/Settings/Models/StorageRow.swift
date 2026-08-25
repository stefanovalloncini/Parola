import SwiftUI
import ParolaCore
import AppKit

struct StorageRow: View {
    @State private var overridePath: String? = Self.currentOverride()
    @State private var showingRestartAlert = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text("Storage:")
                .font(DS.Font.calloutMedium)
                .foregroundStyle(.secondary)
            Text(displayPath)
                .font(DS.Font.calloutMono)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose…") { chooseStorage() }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
            if overridePath != nil {
                Button("Use Default") { resetStorage() }
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
            }
        }
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.vertical, DS.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .fill(DS.Color.surfaceElevated)
        )
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

    private var displayPath: String {
        if let overridePath {
            return (overridePath as NSString).abbreviatingWithTildeInPath
        }
        return (ModelStore.defaultDirectory.path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseStorage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose models folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: ModelStore.storageOverrideKey)
        ModelStore.writeSharedOverride(url.path)
        overridePath = Self.currentOverride()
        showingRestartAlert = true
    }

    private func resetStorage() {
        UserDefaults.standard.removeObject(forKey: ModelStore.storageOverrideKey)
        ModelStore.writeSharedOverride(nil)
        overridePath = Self.currentOverride()
        showingRestartAlert = true
    }
}
