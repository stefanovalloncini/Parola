import SwiftUI
import ParolaCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "slider.horizontal.3") }
            ModelsTab().tabItem { Label("Models", systemImage: "cpu") }
            ToolsTab().tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
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
                Toggle("Highlight the word being spoken", isOn: $model.karaokeHighlight)
                    .onChange(of: model.karaokeHighlight) { _, isOn in
                        if !isOn { model.wordTimestamps = false }
                    }
                Text("Bolds and tints the current word as audio plays. Approximate by default — turn on precise timings below for exact word-level sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Use precise word timings", isOn: $model.wordTimestamps)
                    .disabled(!model.karaokeHighlight)
                Text("Asks Whisper for word-level timestamps during transcription. More accurate karaoke, but transcription is noticeably slower.")
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
                Text("A short list of names or jargon helps Whisper get unusual words right. Plain text, comma-separated.")
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

private struct ToolsTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                ToolStatusRow(
                    name: "yt-dlp",
                    description: "Required to transcribe YouTube URLs. Parola downloads the audio locally; no upload happens.",
                    available: model.ytDlpAvailable,
                    installing: model.ytDlpInstalling,
                    error: model.ytDlpInstallError,
                    install: { model.installYtDlpViaBrew() }
                )
            } header: {
                Text("Optional tools")
            } footer: {
                Text("Parola only uses these tools when you ask it to — none of them are required for local audio or video files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshYtDlpAvailability() }
    }
}

private struct ToolStatusRow: View {
    let name: String
    let description: String
    let available: Bool
    let installing: Bool
    let error: String?
    let install: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: available ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(available ? Color.green : Color.orange)
                Text(name).font(.headline)
                Text(available ? "Installed" : "Not installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !available {
                    Button(action: install) {
                        if installing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Installing…")
                            }
                        } else {
                            Label("Install with Homebrew", systemImage: "arrow.down.circle")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(installing)
                }
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
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
                Text(DS.formatBytes(size)).font(.caption).foregroundStyle(.secondary)
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

