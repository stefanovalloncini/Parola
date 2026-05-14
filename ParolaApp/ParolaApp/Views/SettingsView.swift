import SwiftUI
import ParolaCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "slider.horizontal.3") }
            ModelsTab().tabItem { Label("Models", systemImage: "cpu") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding()
    }
}

private struct GeneralTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Playback") {
                Toggle("Highlight words during playback", isOn: $model.wordTimestamps)
                Text("Word-level highlighting needs precise timestamps. Transcription is slower with this on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Recording") {
                Toggle("Stream microphone in real time", isOn: $model.useStreaming)
                Text("When on, the transcript appears as you speak. Turn off to record first and transcribe at the end.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Custom vocabulary") {
                TextField("Initial prompt", text: $model.initialPrompt, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.roundedBorder)
                Text("A short list of names or jargon helps Whisper get unusual words right. Plain text, comma-separated works fine. Stays under ~200 words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Speakers") {
                Toggle("Identify speakers", isOn: $model.diarize)
                Text("Tags each segment with Speaker 1, Speaker 2, etc. Loads a second model on first use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
        VStack(spacing: DS.Spacing.regular) {
            Image(systemName: "waveform")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(DS.Color.accent)
                .padding(.top, DS.Spacing.large)
            Text("Parola")
                .font(DS.Font.title)
            Text("Version \(Parola.version)")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
            Text("On-device speech-to-text for macOS, built on WhisperKit.")
                .font(DS.Font.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(DS.Color.secondaryText)
                .padding(.horizontal, DS.Spacing.large)
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
