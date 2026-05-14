import SwiftUI
import ParolaCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            ModelsTab().tabItem { Label("Models", systemImage: "cpu") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding()
    }
}

private struct ModelsTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Whisper models are stored at:")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Text(model.cacheDirectoryDisplayPath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button("Reveal") { model.revealCacheDirectory() }
            }

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.availableModels) { entry in
                        ModelRow(entry: entry)
                    }
                }
            }
        }
    }
}

private struct ModelRow: View {
    let entry: ModelInfo
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label).font(.body)
                Text(entry.name).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let size = entry.approximateSizeBytes {
                Text(humanBytes(size)).font(.caption).foregroundStyle(.secondary)
            }
            if entry.isInstalled {
                Button(role: .destructive) {
                    model.deleteModel(entry.name)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.borderless)
            } else {
                Button {
                    model.downloadModel(entry.name)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private func humanBytes(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes); var idx = 0
        while value >= 1024, idx < units.count - 1 { value /= 1024; idx += 1 }
        return String(format: "%.1f %@", value, units[idx])
    }
}

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Parola").font(.largeTitle).bold()
            Text("Version \(Parola.version)").foregroundStyle(.secondary)
            Text("Local speech-to-text on Apple Silicon, powered by WhisperKit.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding()
            Spacer()
        }
        .padding()
    }
}

extension AppModel {
    var cacheDirectoryDisplayPath: String {
        let url = ModelStore.shared.directory
        return url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    func revealCacheDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([ModelStore.shared.directory])
    }
}
