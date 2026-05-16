import SwiftUI
import ParolaCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var route: SettingsRoute = .general
    @State private var search: String = ""

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(route: $route, search: $search)
                .frame(width: 220)
            Divider()
            SettingsDetail(route: route)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 880, idealWidth: 900, maxWidth: .infinity,
               minHeight: 600, idealHeight: 640, maxHeight: .infinity)
    }
}

// MARK: - Routes

private enum SettingsRoute: String, CaseIterable, Identifiable, Hashable {
    case general, customization, watchedFolders, recordMeetings, shortcuts
    case microphone, liveCaptions, dictation
    case localModels, cloudModels, people, translation, ignoredSegments, findReplace
    case exportFormats, batchExport, autoExport, integrations
    case services, prompts
    case advanced, about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .customization: return "Customization"
        case .watchedFolders: return "Watched Folders"
        case .recordMeetings: return "Record Meetings"
        case .shortcuts: return "Shortcuts"
        case .microphone: return "Microphone"
        case .liveCaptions: return "Live Captions"
        case .dictation: return "Dictation"
        case .localModels: return "Local Models"
        case .cloudModels: return "Cloud Models"
        case .people: return "People"
        case .translation: return "Translation"
        case .ignoredSegments: return "Ignored Segments"
        case .findReplace: return "Find & Replace"
        case .exportFormats: return "Export Formats"
        case .batchExport: return "Batch Export"
        case .autoExport: return "Auto-Export"
        case .integrations: return "Integrations"
        case .services: return "Services"
        case .prompts: return "Prompts"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .customization: return "paintbrush"
        case .watchedFolders: return "folder.badge.gearshape"
        case .recordMeetings: return "video.bubble"
        case .shortcuts: return "command"
        case .microphone: return "mic"
        case .liveCaptions: return "captions.bubble"
        case .dictation: return "text.bubble"
        case .localModels: return "cpu"
        case .cloudModels: return "cloud"
        case .people: return "person.2"
        case .translation: return "character.book.closed"
        case .ignoredSegments: return "line.3.horizontal.decrease.circle"
        case .findReplace: return "arrow.triangle.2.circlepath"
        case .exportFormats: return "square.and.arrow.up"
        case .batchExport: return "rectangle.stack.badge.play"
        case .autoExport: return "arrow.up.doc"
        case .integrations: return "puzzlepiece.extension"
        case .services: return "sparkles"
        case .prompts: return "text.cursor"
        case .advanced: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
}

private struct SidebarGroup: Identifiable {
    let id = UUID()
    let title: String?
    let routes: [SettingsRoute]
}

private let sidebarGroups: [SidebarGroup] = [
    SidebarGroup(title: nil, routes: [.general, .customization, .watchedFolders, .recordMeetings, .shortcuts]),
    SidebarGroup(title: "AUDIO & VIDEO", routes: [.microphone, .liveCaptions, .dictation]),
    SidebarGroup(title: "TRANSCRIPTION", routes: [.localModels, .cloudModels, .people, .translation, .ignoredSegments, .findReplace]),
    SidebarGroup(title: "EXPORT", routes: [.exportFormats, .batchExport, .autoExport, .integrations]),
    SidebarGroup(title: "AI", routes: [.services, .prompts]),
    SidebarGroup(title: nil, routes: [.advanced, .about])
]

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var route: SettingsRoute
    @Binding var search: String

    var body: some View {
        VStack(spacing: 0) {
            SearchPill(text: $search)
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(filteredGroups) { group in
                        if let title = group.title {
                            Text(title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.top, 4)
                        }
                        VStack(spacing: 2) {
                            ForEach(group.routes) { r in
                                SidebarRow(route: r, selected: route == r) {
                                    route = r
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .background(.background.secondary)
    }

    private var filteredGroups: [SidebarGroup] {
        let trimmed = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return sidebarGroups }
        return sidebarGroups.compactMap { group in
            let matches = group.routes.filter { $0.label.lowercased().contains(trimmed) }
            return matches.isEmpty ? nil : SidebarGroup(title: group.title, routes: matches)
        }
    }
}

private struct SearchPill: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
            TextField("Search Settings…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
    }
}

private struct SidebarRow: View {
    let route: SettingsRoute
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: route.symbol)
                    .font(.system(size: 13))
                    .frame(width: 16)
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                Text(route.label)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if selected { return .accentColor }
        if hovering { return .secondary.opacity(0.12) }
        return .clear
    }
}

// MARK: - Detail

private struct SettingsDetail: View {
    let route: SettingsRoute
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(route.label)
                    .font(.system(size: 18, weight: .semibold))
                    .padding(.top, 20)
                content
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .general: GeneralPane()
        case .customization: CustomizationPane()
        case .watchedFolders: WatchedFoldersPane()
        case .recordMeetings: RecordMeetingsPane()
        case .shortcuts: ShortcutsPane()
        case .microphone: MicrophonePane()
        case .liveCaptions: LiveCaptionsPane()
        case .dictation: DictationPane()
        case .localModels, .cloudModels:
            Text("Models pane — see Unit 5b").foregroundStyle(.secondary)
        case .people: PeoplePane()
        case .translation: TranslationPane()
        case .ignoredSegments: IgnoredSegmentsPane()
        case .findReplace: FindReplacePane()
        case .exportFormats: ExportFormatsPane()
        case .batchExport: BatchExportPane()
        case .autoExport: AutoExportPane()
        case .integrations: IntegrationsPane()
        case .services: ServicesPane()
        case .prompts: PromptsPane()
        case .advanced: AdvancedPane()
        case .about: AboutPane()
        }
    }
}

// MARK: - Section & row primitives

private struct SettingsSection<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
                    .padding(.bottom, 2)
            }
            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.background.tertiary)
            )
        }
    }
}

private struct SettingRow<Trailing: View>: View {
    let title: String
    let description: String?
    @ViewBuilder var trailing: Trailing
    let isFirst: Bool

    init(_ title: String, description: String? = nil, isFirst: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.description = description
        self.trailing = trailing()
        self.isFirst = isFirst
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst {
                Divider().padding(.leading, 16)
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    if let description {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

private struct SettingHelper: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .italic()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection {
                SettingRow("Highlight the word being spoken",
                           description: "Bolds and tints the current word as audio plays.",
                           isFirst: true) {
                    Toggle("", isOn: $model.karaokeHighlight)
                        .labelsHidden()
                        .onChange(of: model.karaokeHighlight) { _, isOn in
                            if !isOn { model.wordTimestamps = false }
                        }
                }
                SettingRow("Use precise word timings",
                           description: "Asks Whisper for word-level timestamps. More accurate karaoke, but slower.") {
                    Toggle("", isOn: $model.wordTimestamps)
                        .labelsHidden()
                        .disabled(!model.karaokeHighlight)
                }
                SettingRow("Stream microphone in real time",
                           description: "Transcript appears as you speak. Off records the whole take first, then transcribes.") {
                    Toggle("", isOn: $model.useStreaming).labelsHidden()
                }
                SettingRow("Identify speakers",
                           description: "Tags each segment with Speaker 1, Speaker 2, etc. Loads a second model on first use.") {
                    Toggle("", isOn: $model.diarize).labelsHidden()
                }
            }

            SettingsSection("Custom vocabulary") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Names or jargon, comma-separated",
                              text: $model.initialPrompt, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                    Text("A short list of names or jargon helps Whisper get unusual words right.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
        }
    }
}

private struct CustomizationPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SettingsSection {
            SettingRow("Appearance", isFirst: true) {
                Picker("", selection: $model.appTheme) {
                    Text("Match system").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160)
            }
            SettingRow("Monospaced timestamps",
                       description: "Use a fixed-width font for timestamps in the transcript.") {
                Toggle("", isOn: $model.monospacedTimestamps).labelsHidden()
            }
            SettingRow("Sidebar density",
                       description: "Spacing in the library sidebar.") {
                Picker("", selection: $model.sidebarDensity) {
                    Text("Comfortable").tag("comfortable")
                    Text("Compact").tag("compact")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160)
            }
        }
    }
}

private struct WatchedFoldersPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection {
                if model.watchedFolders.folders.isEmpty {
                    HStack {
                        Text("No watched folders yet.")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ForEach(Array(model.watchedFolders.folders.enumerated()), id: \.element.id) { idx, folder in
                        SettingRow(folder.displayName,
                                   description: folder.displayPath,
                                   isFirst: idx == 0) {
                            Button {
                                model.watchedFolders.removeFolder(folder.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Button {
                model.watchedFolders.presentAddFolderPanel()
            } label: {
                Label("Add Folder…", systemImage: "plus.circle")
            }

            SettingHelper(text: "New files dropped into a watched folder are transcribed automatically. Existing files are ignored.")
        }
    }
}

private struct RecordMeetingsPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Auto-detect meeting apps",
                           description: "Offer to record system audio when Zoom, Teams, Webex, or Meet launches.",
                           isFirst: true) {
                    Toggle("", isOn: $model.meetingDetector.isEnabled).labelsHidden()
                }
            }
            SettingHelper(text: "Parola watches running applications; nothing leaves your Mac.")
        }
    }
}

private struct ShortcutsPane: View {
    var body: some View {
        SettingsSection {
            SettingRow("Open Audio…", isFirst: true) { Text("⌘O").foregroundStyle(.secondary) }
            SettingRow("Save Document") { Text("⌘S").foregroundStyle(.secondary) }
            SettingRow("Find") { Text("⌘F").foregroundStyle(.secondary) }
            SettingRow("Toggle Live Captions") { Text("⇧⌘L").foregroundStyle(.secondary) }
            SettingRow("Export as TXT") { Text("⌘E").foregroundStyle(.secondary) }
            SettingRow("Dictation hotkey") { Text("F5").foregroundStyle(.secondary) }
        }
    }
}

private struct MicrophonePane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Microphone Mode",
                           description: "Always use the system's default microphone.",
                           isFirst: true) {
                    Text("System Default").foregroundStyle(.secondary)
                }
            }
            SettingHelper(text: "Change the default microphone in System Settings › Sound.")
        }
    }
}

private struct LiveCaptionsPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Translate to English",
                           description: "Translate captions live as you speak.",
                           isFirst: true) {
                    Toggle("", isOn: Binding(
                        get: { model.liveCaptions.translateToEnglish },
                        set: { newValue in
                            Task { await model.liveCaptions.setTranslate(newValue) }
                        }
                    ))
                    .labelsHidden()
                }
                SettingRow("Status") {
                    Text(model.liveCaptions.isActive ? "Running" : "Stopped")
                        .foregroundStyle(.secondary)
                }
            }
            SettingHelper(text: "Start and stop live captions from the Captions menu (⇧⌘L).")
        }
    }
}

private struct DictationPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection {
                SettingRow("Enable dictation",
                           description: "Hold F5 to dictate; release to paste the text at the cursor.",
                           isFirst: true) {
                    Toggle("", isOn: $model.dictationEnabled).labelsHidden()
                }
                SettingRow("Cleanup mode") {
                    Picker("", selection: $model.dictationCleanupPromptID) {
                        Text("Raw (no cleanup)").tag("")
                        ForEach(Prompt.builtIns) { prompt in
                            Text(prompt.name).tag(prompt.id.uuidString)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
                }
            }
            SettingHelper(text: "Press and hold the dictation key to dictate. Requires Input Monitoring permission.")

            SettingsSection("Per-app overrides") {
                let apps = AppModel.dictationOverrideApps
                ForEach(Array(apps.enumerated()), id: \.element.bundleID) { idx, app in
                    SettingRow(app.name, isFirst: idx == 0) {
                        Picker("", selection: Binding(
                            get: { model.dictationOverridePromptID(for: app.bundleID) },
                            set: { model.setDictationOverridePromptID($0, for: app.bundleID) }
                        )) {
                            Text("Use default").tag("")
                            ForEach(Prompt.builtIns) { prompt in
                                Text(prompt.name).tag(prompt.id.uuidString)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 200)
                    }
                }
            }
            SettingHelper(text: "Override the default cleanup mode when the frontmost app matches.")
        }
    }
}

private struct PeoplePane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Speakers",
                           description: "Names you give to Speaker 1, Speaker 2 stick across transcripts.",
                           isFirst: true) {
                    Text("Auto").foregroundStyle(.secondary)
                }
            }
            SettingHelper(text: "Rename a speaker from the transcript view to teach Parola who's who.")
        }
    }
}

private struct TranslationPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Translate to English by default",
                           description: "Apply translation to every new transcription unless overridden.",
                           isFirst: true) {
                    Toggle("", isOn: $model.translate).labelsHidden()
                }
            }
            SettingHelper(text: "Whisper translates from the detected source language into English.")
        }
    }
}

private struct IgnoredSegmentsPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                if model.ignoredSegmentRules.isEmpty {
                    HStack {
                        Text("No patterns yet.").foregroundStyle(.secondary).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ForEach(Array(model.ignoredSegmentRules.enumerated()), id: \.element.id) { idx, rule in
                        IgnoredRuleRow(rule: $model.ignoredSegmentRules[idx], isFirst: idx == 0) {
                            model.ignoredSegmentRules.removeAll { $0.id == rule.id }
                        }
                    }
                }
            }

            Button {
                model.ignoredSegmentRules.append(IgnoredSegmentRule(pattern: ""))
            } label: {
                Label("Add pattern", systemImage: "plus.circle")
            }

            SettingHelper(text: "Segments matching a pattern (case-insensitive, trimmed) are removed before saving.")
        }
    }
}

private struct IgnoredRuleRow: View {
    @Binding var rule: IgnoredSegmentRule
    let isFirst: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { Divider().padding(.leading, 16) }
            HStack(spacing: 10) {
                Toggle("", isOn: $rule.enabled).labelsHidden()
                TextField("e.g. uh, um, hmm", text: $rule.pattern)
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

private struct FindReplacePane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                if model.findReplaceRules.isEmpty {
                    HStack {
                        Text("No rules yet.").foregroundStyle(.secondary).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ForEach(Array(model.findReplaceRules.enumerated()), id: \.element.id) { idx, rule in
                        FindReplaceRuleRow(rule: $model.findReplaceRules[idx], isFirst: idx == 0) {
                            model.findReplaceRules.removeAll { $0.id == rule.id }
                        }
                    }
                }
            }

            Button {
                model.findReplaceRules.append(FindReplaceRule(find: "", replace: ""))
            } label: {
                Label("Add rule", systemImage: "plus.circle")
            }

            SettingHelper(text: "Substitutions applied to every new transcript before it's saved.")
        }
    }
}

private struct FindReplaceRuleRow: View {
    @Binding var rule: FindReplaceRule
    let isFirst: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { Divider().padding(.leading, 16) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Toggle("", isOn: $rule.enabled).labelsHidden()
                    TextField("find", text: $rule.find).textFieldStyle(.roundedBorder)
                    Text("→").foregroundStyle(.secondary)
                    TextField("replace with", text: $rule.replace).textFieldStyle(.roundedBorder)
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                HStack(spacing: 16) {
                    Toggle("Case-sensitive", isOn: $rule.caseSensitive).toggleStyle(.checkbox)
                    Toggle("Regex", isOn: $rule.regex).toggleStyle(.checkbox)
                }
                .font(.system(size: 11))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

private struct ExportFormatsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                let formats = ExportFormat.allCases
                ForEach(Array(formats.enumerated()), id: \.element) { idx, format in
                    SettingRow(format.rawValue.uppercased(), isFirst: idx == 0) {
                        Text(".\(format.fileExtension)").foregroundStyle(.secondary)
                    }
                }
            }
            SettingHelper(text: "Export the current transcript from the Transcript menu.")
        }
    }
}

private struct BatchExportPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Multi-file transcription",
                           description: "Open multiple audio files at once to queue them for batch transcription.",
                           isFirst: true) {
                    Text("Drag & Drop").foregroundStyle(.secondary)
                }
            }
            SettingHelper(text: "Drop a folder of files on the Parola window to start a batch.")
        }
    }
}

private struct AutoExportPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                if model.autoExportRules.isEmpty {
                    HStack {
                        Text("No rules yet.").foregroundStyle(.secondary).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ForEach(Array(model.autoExportRules.enumerated()), id: \.element.id) { idx, rule in
                        AutoExportRuleRow(rule: $model.autoExportRules[idx], isFirst: idx == 0) {
                            model.autoExportRules.removeAll { $0.id == rule.id }
                        }
                    }
                }
            }

            Button {
                model.autoExportRules.append(
                    AutoExportRule(sourceExtensions: ["mp4"], outputFormats: [.srt])
                )
            } label: {
                Label("Add rule", systemImage: "plus.circle")
            }

            SettingHelper(text: "Auto-export writes additional files next to the source when transcription completes.")
        }
    }
}

private struct AutoExportRuleRow: View {
    @Binding var rule: AutoExportRule
    let isFirst: Bool
    let onDelete: () -> Void
    @State private var extensionsText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { Divider().padding(.leading, 16) }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("", isOn: $rule.enabled).labelsHidden()
                    Text(summary).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                HStack {
                    Text("When source is").font(.system(size: 11)).foregroundStyle(.secondary)
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
                    Text("Also write").font(.system(size: 11)).foregroundStyle(.secondary)
                    AutoExportFormatChips(selected: $rule.outputFormats)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
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

private struct IntegrationsPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                ToolStatusRow(
                    name: "yt-dlp",
                    description: "Required to transcribe YouTube URLs. Audio downloads locally; no upload happens.",
                    available: model.ytDlpAvailable,
                    installing: model.ytDlpInstalling,
                    error: model.ytDlpInstallError,
                    isFirst: true,
                    install: { model.installYtDlpViaBrew() }
                )
            }
            SettingHelper(text: "Parola only uses these tools when you ask it to.")
        }
        .onAppear { model.refreshYtDlpAvailability() }
    }
}

private struct ToolStatusRow: View {
    let name: String
    let description: String
    let available: Bool
    let installing: Bool
    let error: String?
    let isFirst: Bool
    let install: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { Divider().padding(.leading, 16) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: available ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(available ? Color.green : Color.orange)
                    Text(name).font(.system(size: 13, weight: .semibold))
                    Text(available ? "Installed" : "Not installed")
                        .font(.system(size: 11))
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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

private struct ServicesPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("On-device language model",
                           description: "Uses Apple's on-device foundation model when available.",
                           isFirst: true) {
                    Text("Built-in").foregroundStyle(.secondary)
                }
                SettingRow("Cloud providers",
                           description: "Bring-your-own-key support is configured in the main window.") {
                    Text("BYOK").foregroundStyle(.secondary)
                }
            }
            SettingHelper(text: "API keys are stored in the macOS keychain.")
        }
    }
}

private struct PromptsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                let prompts = Prompt.builtIns
                ForEach(Array(prompts.enumerated()), id: \.element.id) { idx, prompt in
                    SettingRow(prompt.name, isFirst: idx == 0) {
                        Text("Built-in").foregroundStyle(.secondary)
                    }
                }
            }
            SettingHelper(text: "Prompts rewrite transcripts after recording — used by dictation cleanup and the Transcript menu.")
        }
    }
}

private struct AdvancedPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection("Model storage") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.cacheDirectoryDisplayPath)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                    Button("Reveal in Finder") { model.revealCacheDirectory() }
                }
                .padding(16)
            }
        }
    }
}

private struct AboutPane: View {
    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
                .padding(.top, 32)
            Text("Parola").font(.system(size: 22, weight: .semibold))
            Text("Version \(Parola.version)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("On-device speech-to-text for macOS, built on WhisperKit.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
