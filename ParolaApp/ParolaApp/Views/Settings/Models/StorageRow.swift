import SwiftUI
import ParolaCore

struct StorageRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text("Storage:")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(displayPath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose…") { chooseStorage() }
                .controlSize(.small)
            if isCustom {
                Button("Use Default") { resetStorage() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var displayPath: String {
        let custom = UserDefaults.standard.string(forKey: ModelStore.storageOverrideKey)
        if let custom, !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return (custom as NSString).abbreviatingWithTildeInPath
        }
        return (ModelStore.defaultDirectory.path as NSString).abbreviatingWithTildeInPath
    }

    private var isCustom: Bool {
        UserDefaults.standard.string(forKey: ModelStore.storageOverrideKey)?
            .trimmingCharacters(in: .whitespaces).isEmpty == false
    }

    private func chooseStorage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose models folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: ModelStore.storageOverrideKey)
        showRestartAlert()
    }

    private func resetStorage() {
        UserDefaults.standard.removeObject(forKey: ModelStore.storageOverrideKey)
        showRestartAlert()
    }

    private func showRestartAlert() {
        let alert = NSAlert()
        alert.messageText = "Restart required"
        alert.informativeText = "Quit and relaunch Parola for the new models folder to take effect."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
