import SwiftUI
import ParolaCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "slider.horizontal.3") }
            ModelsTab().tabItem { Label("Models", systemImage: "cpu") }
            ToolsTab().tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
            AutoExportTab().tabItem { Label("Auto-Export", systemImage: "square.and.arrow.up") }
            FiltersTab().tabItem { Label("Filters", systemImage: "line.3.horizontal.decrease.circle") }
            WatchedFoldersTab().tabItem { Label("Watched", systemImage: "folder.badge.gearshape") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding()
    }
}

private struct WatchedFoldersTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                if model.watchedFolders.folders.isEmpty {
                    Text("No watched folders yet.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(model.watchedFolders.folders) { folder in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.displayName).font(.body)
                                Text(folder.displayPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                model.watchedFolders.removeFolder(folder.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                }
                Button {
                    model.watchedFolders.presentAddFolderPanel()
                } label: {
                    Label("Add Folder…", systemImage: "plus.circle")
                }
            } header: {
                Text("Watched folders")
            } footer: {
                Text("New audio or video files dropped into a watched folder are transcribed automatically. Existing files are ignored — only files added after the folder is being watched count.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct FiltersTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach($model.ignoredSegmentRules) { $rule in
                    HStack {
                        Toggle("Enabled", isOn: $rule.enabled).labelsHidden()
                        TextField("e.g. uh, um, hmm", text: $rule.pattern)
                            .textFieldStyle(.roundedBorder)
                        Button(role: .destructive) {
                            model.ignoredSegmentRules.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    model.ignoredSegmentRules.append(IgnoredSegmentRule(pattern: ""))
                } label: {
                    Label("Add pattern", systemImage: "plus.circle")
                }
            } header: {
                Text("Ignored segments")
            } footer: {
                Text("Segments whose text exactly matches a pattern (case-insensitive, trimmed) are removed from the transcript before it's saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach($model.findReplaceRules) { $rule in
                    VStack(alignment: .leading, spacing: DS.Spacing.small) {
                        HStack {
                            Toggle("Enabled", isOn: $rule.enabled).labelsHidden()
                            TextField("find", text: $rule.find).textFieldStyle(.roundedBorder)
                            Text("→").foregroundStyle(.secondary)
                            TextField("replace with", text: $rule.replace).textFieldStyle(.roundedBorder)
                            Button(role: .destructive) {
                                model.findReplaceRules.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        HStack {
                            Toggle("Case-sensitive", isOn: $rule.caseSensitive)
                                .toggleStyle(.checkbox)
                            Toggle("Regex", isOn: $rule.regex)
                                .toggleStyle(.checkbox)
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
                Button {
                    model.findReplaceRules.append(FindReplaceRule(find: "", replace: ""))
                } label: {
                    Label("Add rule", systemImage: "plus.circle")
                }
            } header: {
                Text("Find & replace")
            } footer: {
                Text("Substitutions applied to every new transcript before it's saved. Per-document find & replace stays in the main window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AutoExportTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach($model.autoExportRules) { $rule in
                    AutoExportRuleRow(rule: $rule) {
                        model.autoExportRules.removeAll { $0.id == rule.id }
                    }
                }
                Button {
                    model.autoExportRules.append(
                        AutoExportRule(sourceExtensions: ["mp4"], outputFormats: [.srt])
                    )
                } label: {
                    Label("Add rule", systemImage: "plus.circle")
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("Auto-export rules write additional files next to your source whenever a transcription completes. Files are written only when the source location is writable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AutoExportRuleRow: View {
    @Binding var rule: AutoExportRule
    let onDelete: () -> Void
    @State private var extensionsText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack {
                Toggle("Enabled", isOn: $rule.enabled).labelsHidden()
                Text(summary).font(.body.weight(.medium))
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            HStack {
                Text("When source is").font(.caption).foregroundStyle(.secondary)
                TextField("mp4, mov", text: $extensionsText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: extensionsText) { _, new in
                        rule.sourceExtensions = Set(
                            new.split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                                .filter { !$0.isEmpty }
                        )
                    }
            }
            HStack(alignment: .top) {
                Text("Also write").font(.caption).foregroundStyle(.secondary)
                AutoExportFormatChips(selected: $rule.outputFormats)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            extensionsText = rule.sourceExtensions.sorted().joined(separator: ", ")
        }
    }

    private var summary: String {
        let exts = rule.sourceExtensions.sorted().joined(separator: ", ")
        let fmts = rule.outputFormats.map(\.rawValue).sorted().joined(separator: ", ")
        let left = exts.isEmpty ? "any" : exts
        let right = fmts.isEmpty ? "nothing" : fmts
        return "\(left) → \(right)"
    }
}

private struct AutoExportFormatChips: View {
    @Binding var selected: Set<ExportFormat>

    var body: some View {
        let grid = [GridItem(.adaptive(minimum: 50))]
        LazyVGrid(columns: grid, alignment: .leading, spacing: 4) {
            ForEach(ExportFormat.allCases, id: \.self) { format in
                let isOn = selected.contains(format)
                Button(format.fileExtension) {
                    if isOn { selected.remove(format) } else { selected.insert(format) }
                }
                .buttonStyle(.bordered)
                .tint(isOn ? .accentColor : .secondary)
                .controlSize(.small)
            }
        }
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

