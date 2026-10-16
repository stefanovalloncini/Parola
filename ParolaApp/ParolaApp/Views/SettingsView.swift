import SwiftUI
import ParolaCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var search: String = ""

    private var route: Binding<SettingsRoute> {
        Binding(
            get: {
                let stored = SettingsRoute(rawValue: model.settingsPane) ?? .general
                return stored.isVisible(features: model.features) ? stored : .general
            },
            set: {
                // In the same update as the switch: the editor's onDisappear would repaint after the next pane appeared.
                model.commitPaletteDraft()
                model.settingsPane = $0.rawValue
            }
        )
    }

    private var selection: Binding<SettingsRoute?> {
        Binding(
            get: { route.wrappedValue },
            set: { if let picked = $0 { route.wrappedValue = picked } }
        )
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: selection, search: search, features: model.features)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            SettingsDetail(route: route.wrappedValue)
        }
        .searchable(text: $search, placement: .sidebar, prompt: Text("Search Settings…"))
        .frame(minWidth: 880, idealWidth: 900, maxWidth: .infinity,
               minHeight: 600, idealHeight: 640, maxHeight: .infinity)
        .axBranch("Settings")
    }
}

// MARK: - Routes

enum SettingsRoute: String, CaseIterable, Identifiable, Hashable {
    case general, customization, watchedFolders, recordMeetings, shortcuts
    case microphone, liveCaptions, dictation, snippets, corrections
    case localModels, transcriptionDefaults, translation, readAloud, people, ignoredSegments, findReplace
    case exportFormats, batchExport, autoExport, sendTo, integrations
    case aiServices, prompts
    case automation
    case updates
    case advanced

    var id: String { rawValue }

    private var meta: SettingsRouteMeta { SettingsRouteMeta.table[self]! }

    var label: String { String(localized: String.LocalizationValue(meta.titleKey)) }
    var localizedLabelKey: LocalizedStringKey { LocalizedStringKey(meta.titleKey) }
    var summary: String { String(localized: String.LocalizationValue(meta.summaryKey)) }
    var localizedSummaryKey: LocalizedStringKey { LocalizedStringKey(meta.summaryKey) }
    var symbol: String { meta.symbol }
    var paneScope: SettingsPaneScope? { meta.scope }

    func isVisible(features: FeatureSet) -> Bool {
        switch self {
        case .dictation, .snippets, .corrections:
            return features.isEnabled(.dictation)
        case .recordMeetings: return features.isEnabled(.meetings)
        case .liveCaptions: return features.isEnabled(.liveCaptions)
        case .batchExport: return features.isEnabled(.batch)
        case .prompts, .aiServices: return features.isEnabled(.ai)
        case .automation: return features.isEnabled(.automation)
        case .watchedFolders: return features.isEnabled(.watchedFolders)
        case .sendTo: return features.isEnabled(.destinations)
        case .microphone:
            return features.isEnabled(.micRecording) || features.isEnabled(.dictation)
                || features.isEnabled(.liveCaptions)
        // The pane only hosts the yt-dlp installer today.
        case .integrations: return features.isEnabled(.youtube)
        default: return true
        }
    }

    /// Search terms for routes without a pane scope; scoped routes get theirs from the scope.
    var extraSearchKeywords: [String] {
        switch self {
        case .localModels: return ["model", "whisper", "parakeet", "apple speech", "download", "storage", "delete", "activate", "default", "models folder", "model storage", "cache", "reveal"]
        default: return []
        }
    }

    var searchTerms: [String] {
        var terms = [label.lowercased(), summary.lowercased()]
        terms.append(contentsOf: extraSearchKeywords.map { $0.lowercased() })
        if let paneScope {
            terms.append(contentsOf: paneScope.searchKeywords.map { $0.lowercased() })
        }
        return terms
    }
}

private struct SettingsRouteMeta {
    let titleKey: String
    let summaryKey: String
    let symbol: String
    let scope: SettingsPaneScope?

    static let table: [SettingsRoute: SettingsRouteMeta] = [
        .general: SettingsRouteMeta(titleKey: "General", summaryKey: "How Parola starts up, plus defaults that apply to every transcript.", symbol: "gearshape", scope: .general),
        .customization: SettingsRouteMeta(titleKey: "Customization", summaryKey: "Appearance, theme colors and timestamp font.", symbol: "paintbrush", scope: .customization),
        .watchedFolders: SettingsRouteMeta(titleKey: "Watched Folders", summaryKey: "Folders Parola watches, so anything dropped in is transcribed on its own.", symbol: "folder.badge.gearshape", scope: .watchedFolders),
        .recordMeetings: SettingsRouteMeta(titleKey: "Record Meetings", summaryKey: "Recording meeting audio, and what Parola does when a meeting app starts.", symbol: "video.bubble", scope: .recordMeetings),
        .shortcuts: SettingsRouteMeta(titleKey: "Shortcuts", summaryKey: "The dictation and recording shortcuts that work from any app.", symbol: "command", scope: .shortcuts),
        .microphone: SettingsRouteMeta(titleKey: "Microphone", summaryKey: "Which input Parola records from, and what happens while recording.", symbol: "mic", scope: .microphone),
        .liveCaptions: SettingsRouteMeta(titleKey: "Live Captions", summaryKey: "Captions of what you say or what your Mac plays, in a floating window.", symbol: "captions.bubble", scope: .liveCaptions),
        .dictation: SettingsRouteMeta(titleKey: "Dictation", summaryKey: "The hotkey that turns speech into text in any app.", symbol: "text.bubble", scope: .dictation),
        .snippets: SettingsRouteMeta(titleKey: "Snippets", summaryKey: "Short triggers that expand into longer text while you dictate.", symbol: "text.append", scope: .snippets),
        .corrections: SettingsRouteMeta(titleKey: "Corrections", summaryKey: "Word replacements applied to dictated text after each take.", symbol: "wand.and.rays", scope: .corrections),
        .localModels: SettingsRouteMeta(titleKey: "Local Models", summaryKey: "Speech models on this Mac, and the space they take up.", symbol: "cpu", scope: nil),
        .transcriptionDefaults: SettingsRouteMeta(titleKey: "Transcription Defaults", summaryKey: "The model and language new transcriptions start with.", symbol: "slider.horizontal.3", scope: .transcriptionDefaults),
        .translation: SettingsRouteMeta(titleKey: "Translation", summaryKey: "How Parola translates a transcript, and how it shows the result.", symbol: "character.book.closed", scope: .translation),
        .readAloud: SettingsRouteMeta(titleKey: "Read Aloud", summaryKey: "The voice Parola reads with, one for each language.", symbol: "speaker.wave.2", scope: .readAloud),
        .people: SettingsRouteMeta(titleKey: "People", summaryKey: "The speakers you name, the colour each one wears, and where they show up.", symbol: "person.2", scope: .people),
        .ignoredSegments: SettingsRouteMeta(titleKey: "Ignored Segments", summaryKey: "Segments dropped from a transcript when the text matches a pattern.", symbol: "line.3.horizontal.decrease.circle", scope: .ignoredSegments),
        .findReplace: SettingsRouteMeta(titleKey: "Find & Replace", summaryKey: "Substitutions applied to every transcript before it's saved.", symbol: "arrow.triangle.2.circlepath", scope: .findReplace),
        .exportFormats: SettingsRouteMeta(titleKey: "Export Presets", summaryKey: "The named exports Parola can write, and what each one puts in the file.", symbol: "square.and.arrow.up", scope: .exportFormats),
        .batchExport: SettingsRouteMeta(titleKey: "Batch Export", summaryKey: "What happens to files exported from a batch run.", symbol: "rectangle.stack.badge.play", scope: .batchExport),
        .autoExport: SettingsRouteMeta(titleKey: "Auto-Export", summaryKey: "Rules that write a transcript to disk as soon as it's ready.", symbol: "arrow.up.doc", scope: .autoExport),
        .sendTo: SettingsRouteMeta(titleKey: "Send To", summaryKey: "Where a finished transcript is sent, starting with a folder in your Obsidian vault.", symbol: "paperplane", scope: .sendTo),
        .integrations: SettingsRouteMeta(titleKey: "Links", summaryKey: "The yt-dlp tool Parola uses to download the audio of a link.", symbol: "link", scope: .integrations),
        .aiServices: SettingsRouteMeta(titleKey: "AI Services", summaryKey: "Which model answers each AI task: Apple Intelligence on this Mac, or a service you configure.", symbol: "sparkles", scope: .aiServices),
        .prompts: SettingsRouteMeta(titleKey: "Prompts", summaryKey: "The prompt library behind dictation cleanup and the Transcript menu.", symbol: "text.cursor", scope: .prompts),
        .automation: SettingsRouteMeta(titleKey: "MCP & Automation", summaryKey: "The MCP server other apps and agents use to drive Parola.", symbol: "bolt.horizontal.circle", scope: .automation),
        .updates: SettingsRouteMeta(titleKey: "Updates", summaryKey: "How Parola checks for new versions.", symbol: "arrow.down.circle", scope: .updates),
        .advanced: SettingsRouteMeta(titleKey: "Advanced", summaryKey: "Backup, restore and reset for your settings, and the diagnostics log.", symbol: "wrench.and.screwdriver", scope: .advanced)
    ]
}

struct SidebarGroup: Identifiable {
    let id: String
    let titleKey: String
    let routes: [SettingsRoute]

    var title: LocalizedStringKey { LocalizedStringKey(titleKey) }
}

enum SettingsSidebarCatalog {
    static var all: [SidebarGroup] {
        [
            SidebarGroup(id: "start", titleKey: "Settings.Group.App", routes: [.general, .customization, .shortcuts, .updates]),
            SidebarGroup(id: "capture", titleKey: "Settings.Group.Capture", routes: [.microphone, .recordMeetings, .liveCaptions]),
            SidebarGroup(id: "dictation", titleKey: "Settings.Group.Dictation", routes: [.dictation, .snippets, .corrections]),
            SidebarGroup(id: "sources", titleKey: "Settings.Group.Sources", routes: [.watchedFolders, .integrations]),
            SidebarGroup(id: "transcription", titleKey: "Settings.Group.Transcription", routes: [.localModels, .transcriptionDefaults, .translation, .readAloud, .people, .ignoredSegments, .findReplace]),
            SidebarGroup(id: "export", titleKey: "Settings.Group.Export", routes: [.exportFormats, .batchExport, .autoExport, .sendTo]),
            SidebarGroup(id: "ai", titleKey: "Settings.Group.AI", routes: [.aiServices, .prompts]),
            SidebarGroup(id: "automation", titleKey: "Settings.Group.Automation", routes: [.automation]),
            SidebarGroup(id: "end", titleKey: "Settings.Group.Support", routes: [.advanced])
        ]
    }

    static func visibleGroups(features: FeatureSet, search: String) -> [SidebarGroup] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return all.compactMap { group in
            let routes = group.routes.filter { route in
                route.isVisible(features: features) && (query.isEmpty || matches(route: route, query: query, features: features))
            }
            return routes.isEmpty ? nil : SidebarGroup(id: group.id, titleKey: group.titleKey, routes: routes)
        }
    }

    static func matches(route: SettingsRoute, query: String, features: FeatureSet = .all) -> Bool {
        if searchTerms[route]?.contains(where: { $0.contains(query) }) ?? false { return true }
        let buildTerms = route.paneScope?.searchKeywords(features: features) ?? []
        return buildTerms.contains { $0.lowercased().contains(query) }
    }

    /// Lowercased once per launch — a macOS app can't change its language without relaunching.
    private static let searchTerms: [SettingsRoute: [String]] = Dictionary(
        uniqueKeysWithValues: SettingsRoute.allCases.map { ($0, $0.searchTerms) }
    )
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var selection: SettingsRoute?
    let search: String
    let features: FeatureSet

    var body: some View {
        List(selection: $selection) {
            ForEach(SettingsSidebarCatalog.visibleGroups(features: features, search: search)) { group in
                Section(group.title) {
                    ForEach(group.routes) { route in
                        Label {
                            Text(route.localizedLabelKey)
                        } icon: {
                            SettingsIconTile(symbol: route.symbol, color: DS.settingsGroupTint(for: group.id))
                        }
                        .tag(route)
                        .axLeaf("Sidebar.Button.\(route.rawValue)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// System Settings' sidebar tile: a filled glyph in white on a rounded square of one system colour.
private struct SettingsIconTile: View {
    let symbol: String
    let color: Color
    var side: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .symbolVariant(.fill)
            .font(.system(size: side * 0.55, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: side * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Detail

private struct SettingsDetail: View {
    let route: SettingsRoute
    @Environment(AppModel.self) private var model

    var body: some View {
        route.pane
            .navigationTitle(route.label)
            .navigationSubtitle(route.summary)
            .id(model.themeRevision)
    }
}

extension SettingsRoute {
    @MainActor @ViewBuilder
    var pane: some View {
        switch self {
        case .general: GeneralPane()
        case .customization: CustomizationPane()
        case .watchedFolders: WatchedFoldersPane()
        case .recordMeetings: RecordMeetingsPane()
        case .shortcuts: ShortcutsPane()
        case .microphone: MicrophonePane()
        case .liveCaptions: LiveCaptionsPane()
        case .dictation: DictationPane()
        case .snippets: SnippetsPane()
        case .corrections: CorrectionsPane()
        case .localModels: ModelsSettingsPane()
        case .transcriptionDefaults: TranscriptionDefaultsPane()
        case .translation: TranslationPane()
        case .readAloud: ReadAloudPane()
        case .people: PeoplePane()
        case .ignoredSegments: IgnoredSegmentsPane()
        case .findReplace: FindReplacePane()
        case .exportFormats: ExportFormatsPane()
        case .batchExport: BatchExportSettingsPane()
        case .autoExport: AutoExportPane()
        case .sendTo: SendToPane()
        case .integrations: IntegrationsPane()
        case .aiServices: AIServicesPane()
        case .prompts: PromptsPane()
        case .automation: AutomationPane()
        case .updates: UpdatesPane()
        case .advanced: AdvancedPane()
        }
    }
}

// MARK: - Section & row primitives

/// A pane's page: one grouped form, so its sections and rows take the system's type, spacing and row height.
struct SettingsForm<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
    }
}

struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey?
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            if let title {
                Text(title)
            }
        }
    }
}

struct SettingRow<Trailing: View>: View {
    private let titleText: Text
    private let descriptionText: Text?
    @ViewBuilder var trailing: Trailing

    init(_ title: LocalizedStringKey, description: LocalizedStringKey? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.titleText = Text(title)
        self.descriptionText = description.map { Text($0) }
        self.trailing = trailing()
    }

    init(_ title: LocalizedStringKey, descriptionVerbatim: String?, @ViewBuilder trailing: () -> Trailing) {
        self.titleText = Text(title)
        self.descriptionText = descriptionVerbatim.map { Text($0) }
        self.trailing = trailing()
    }

    init(titleVerbatim: String, description: LocalizedStringKey? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.titleText = Text(titleVerbatim)
        self.descriptionText = description.map { Text($0) }
        self.trailing = trailing()
    }

    init(titleVerbatim: String, descriptionVerbatim: String?, @ViewBuilder trailing: () -> Trailing) {
        self.titleText = Text(titleVerbatim)
        self.descriptionText = descriptionVerbatim.map { Text($0) }
        self.trailing = trailing()
    }

    var body: some View {
        LabeledContent {
            trailing
                .toggleStyle(.switch)
        } label: {
            titleText
            if let descriptionText {
                descriptionText
            }
        }
    }
}

/// A warning line for a section's footer or a row's notes: the triangle and the text in the warning colour.
struct SettingsWarning: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(DS.Color.warningText)
    }
}

/// A note under the section before it, where a grouped form puts a footer.
struct SettingHelper: View {
    let text: LocalizedStringKey
    var body: some View {
        Section {
        } footer: {
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
