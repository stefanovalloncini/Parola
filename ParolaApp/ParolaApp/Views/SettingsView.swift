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
            set: { model.settingsPane = $0.rawValue }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(route: route, search: $search, features: model.features)
                .frame(width: 220)
            Divider()
            SettingsDetail(route: route.wrappedValue)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 880, idealWidth: 900, maxWidth: .infinity,
               minHeight: 600, idealHeight: 640, maxHeight: .infinity)
        .axBranch("Settings")
    }
}

// MARK: - Routes

enum SettingsRoute: String, CaseIterable, Identifiable, Hashable {
    case general, customization, watchedFolders, recordMeetings, shortcuts
    case microphone, liveCaptions, dictation, snippets, corrections
    case localModels, transcriptionDefaults, translation, ignoredSegments, findReplace
    case exportFormats, batchExport, autoExport, integrations
    case prompts
    case automation
    case updates
    case advanced, about

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
        case .prompts: return features.isEnabled(.ai)
        case .automation: return features.isEnabled(.automation)
        case .watchedFolders: return features.isEnabled(.watchedFolders)
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
        case .localModels: return ["model", "whisper", "parakeet", "apple speech", "download", "storage", "delete", "activate"]
        case .about: return ["version", "repository", "diagnostics"]
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
        .customization: SettingsRouteMeta(titleKey: "Customization", summaryKey: "Theme colors and how dense the interface is.", symbol: "paintbrush", scope: .customization),
        .watchedFolders: SettingsRouteMeta(titleKey: "Watched Folders", summaryKey: "Folders Parola watches, so anything dropped in is transcribed on its own.", symbol: "folder.badge.gearshape", scope: .watchedFolders),
        .recordMeetings: SettingsRouteMeta(titleKey: "Record Meetings", summaryKey: "Recording meeting audio, and what Parola does when a meeting app starts.", symbol: "video.bubble", scope: .recordMeetings),
        .shortcuts: SettingsRouteMeta(titleKey: "Shortcuts", summaryKey: "Keyboard shortcuts for the main window commands.", symbol: "command", scope: .shortcuts),
        .microphone: SettingsRouteMeta(titleKey: "Microphone", summaryKey: "Which input Parola records from, and what happens while recording.", symbol: "mic", scope: .microphone),
        .liveCaptions: SettingsRouteMeta(titleKey: "Live Captions", summaryKey: "Live transcription of what you hear, in a floating window.", symbol: "captions.bubble", scope: .liveCaptions),
        .dictation: SettingsRouteMeta(titleKey: "Dictation", summaryKey: "The hotkey that turns speech into text in any app.", symbol: "text.bubble", scope: .dictation),
        .snippets: SettingsRouteMeta(titleKey: "Snippets", summaryKey: "Short triggers that expand into longer text while you dictate.", symbol: "text.append", scope: .snippets),
        .corrections: SettingsRouteMeta(titleKey: "Corrections", summaryKey: "Word replacements applied to dictated text after each take.", symbol: "wand.and.rays", scope: .corrections),
        .localModels: SettingsRouteMeta(titleKey: "Local Models", summaryKey: "Speech models on this Mac, and the space they take up.", symbol: "cpu", scope: nil),
        .transcriptionDefaults: SettingsRouteMeta(titleKey: "Transcription Defaults", summaryKey: "The model and language new transcriptions start with.", symbol: "slider.horizontal.3", scope: .transcriptionDefaults),
        .translation: SettingsRouteMeta(titleKey: "Translation", summaryKey: "Whether Parola translates transcripts into English as it works.", symbol: "character.book.closed", scope: .translation),
        .ignoredSegments: SettingsRouteMeta(titleKey: "Ignored Segments", summaryKey: "Segments dropped from a transcript when the text matches a pattern.", symbol: "line.3.horizontal.decrease.circle", scope: .ignoredSegments),
        .findReplace: SettingsRouteMeta(titleKey: "Find & Replace", summaryKey: "Substitutions applied to every transcript before it's saved.", symbol: "arrow.triangle.2.circlepath", scope: .findReplace),
        .exportFormats: SettingsRouteMeta(titleKey: "Export Formats", summaryKey: "What each export format puts in the file.", symbol: "square.and.arrow.up", scope: .exportFormats),
        .batchExport: SettingsRouteMeta(titleKey: "Batch Export", summaryKey: "What happens to files exported from a batch run.", symbol: "rectangle.stack.badge.play", scope: .batchExport),
        .autoExport: SettingsRouteMeta(titleKey: "Auto-Export", summaryKey: "Rules that write a transcript to disk as soon as it's ready.", symbol: "arrow.up.doc", scope: .autoExport),
        .integrations: SettingsRouteMeta(titleKey: "Integrations", summaryKey: "Helper tools Parola uses to fetch audio from links.", symbol: "puzzlepiece.extension", scope: .integrations),
        .prompts: SettingsRouteMeta(titleKey: "Prompts", summaryKey: "The prompt library behind dictation cleanup and the Transcript menu.", symbol: "text.cursor", scope: .prompts),
        .automation: SettingsRouteMeta(titleKey: "MCP & Automation", summaryKey: "The MCP server other apps and agents use to drive Parola.", symbol: "bolt.horizontal.circle", scope: .automation),
        .updates: SettingsRouteMeta(titleKey: "Updates", summaryKey: "How Parola checks for new versions.", symbol: "arrow.down.circle", scope: .updates),
        .advanced: SettingsRouteMeta(titleKey: "Advanced", summaryKey: "Where models are stored, plus backup and reset.", symbol: "wrench.and.screwdriver", scope: .advanced),
        .about: SettingsRouteMeta(titleKey: "About", summaryKey: "Version and project links.", symbol: "info.circle", scope: nil)
    ]
}

struct SidebarGroup: Identifiable {
    let id: String
    let title: LocalizedStringKey?
    let routes: [SettingsRoute]
}

enum SettingsSidebarCatalog {
    static var all: [SidebarGroup] {
        [
            SidebarGroup(id: "start", title: "APP", routes: [.general, .customization, .shortcuts, .updates]),
            SidebarGroup(id: "capture", title: "CAPTURE", routes: [.microphone, .recordMeetings, .liveCaptions]),
            SidebarGroup(id: "dictation", title: "DICTATION", routes: [.dictation, .snippets, .corrections]),
            SidebarGroup(id: "sources", title: "SOURCES", routes: [.watchedFolders, .integrations]),
            SidebarGroup(id: "transcription", title: "TRANSCRIPTION", routes: [.localModels, .transcriptionDefaults, .translation, .ignoredSegments, .findReplace]),
            SidebarGroup(id: "export", title: "EXPORT", routes: [.exportFormats, .batchExport, .autoExport]),
            SidebarGroup(id: "ai", title: "AI", routes: [.prompts]),
            SidebarGroup(id: "automation", title: "AUTOMATION", routes: [.automation]),
            SidebarGroup(id: "end", title: "SUPPORT", routes: [.advanced, .about])
        ]
    }

    static func visibleGroups(features: FeatureSet, search: String) -> [SidebarGroup] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return all.compactMap { group in
            let routes = group.routes.filter { route in
                route.isVisible(features: features) && (query.isEmpty || matches(route: route, query: query))
            }
            return routes.isEmpty ? nil : SidebarGroup(id: group.id, title: group.title, routes: routes)
        }
    }

    static func matches(route: SettingsRoute, query: String) -> Bool {
        searchTerms[route]?.contains { $0.contains(query) } ?? false
    }

    /// Lowercased once per launch — a macOS app can't change its language without relaunching.
    private static let searchTerms: [SettingsRoute: [String]] = Dictionary(
        uniqueKeysWithValues: SettingsRoute.allCases.map { ($0, $0.searchTerms) }
    )
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var route: SettingsRoute
    @Binding var search: String
    let features: FeatureSet

    var body: some View {
        VStack(spacing: 0) {
            SearchPill(text: $search, placeholder: "Search Settings…")
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(filteredGroups) { group in
                        if let title = group.title {
                            Text(title)
                                .font(DS.Font.captionEmphasized)
                                .foregroundStyle(DS.Color.secondaryText)
                                .padding(.horizontal, 16)
                                .padding(.top, 4)
                        }
                        VStack(spacing: 2) {
                            ForEach(group.routes) { r in
                                SidebarRow(
                                    title: r.localizedLabelKey,
                                    systemImage: r.symbol,
                                    isSelected: route == r,
                                    height: 28
                                ) {
                                    route = r
                                }
                                .axLeaf("Sidebar.Button.\(r.rawValue)")
                                .accessibilityLabel(r.label)
                                .padding(.horizontal, 8)
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .background(DS.Palette.canvas)
    }

    private var filteredGroups: [SidebarGroup] {
        SettingsSidebarCatalog.visibleGroups(features: features, search: search)
    }
}

// MARK: - Detail

private struct SettingsDetail: View {
    let route: SettingsRoute
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(route.localizedLabelKey)
                        .font(DS.Font.title3)
                    Text(route.localizedSummaryKey)
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 20)
                content
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.Palette.surface)
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
        case .snippets: SnippetsPane()
        case .corrections: CorrectionsPane()
        case .localModels:
            ModelsSettingsPane()
        case .transcriptionDefaults: TranscriptionDefaultsPane()
        case .translation: TranslationPane()
        case .ignoredSegments: IgnoredSegmentsPane()
        case .findReplace: FindReplacePane()
        case .exportFormats: ExportFormatsPane()
        case .batchExport: BatchExportSettingsPane()
        case .autoExport: AutoExportPane()
        case .integrations: IntegrationsPane()
        case .prompts: PromptsPane()
        case .automation: AutomationPane()
        case .updates: UpdatesPane()
        case .advanced: AdvancedPane()
        case .about: AboutPane()
        }
    }
}

// MARK: - Section & row primitives

struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey?
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(DS.Font.heading)
                    .padding(.bottom, 2)
            }
            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                    .fill(DS.Color.surfaceElevated)
            )
        }
    }
}

struct SettingRow<Trailing: View>: View {
    private let titleText: Text
    private let descriptionText: Text?
    @ViewBuilder var trailing: Trailing
    let isFirst: Bool

    init(_ title: LocalizedStringKey, description: LocalizedStringKey? = nil, isFirst: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.titleText = Text(title)
        self.descriptionText = description.map { Text($0) }
        self.trailing = trailing()
        self.isFirst = isFirst
    }

    init(_ title: LocalizedStringKey, descriptionVerbatim: String?, isFirst: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.titleText = Text(title)
        self.descriptionText = descriptionVerbatim.map { Text($0) }
        self.trailing = trailing()
        self.isFirst = isFirst
    }

    init(titleVerbatim: String, description: LocalizedStringKey? = nil, isFirst: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.titleText = Text(titleVerbatim)
        self.descriptionText = description.map { Text($0) }
        self.trailing = trailing()
        self.isFirst = isFirst
    }

    init(titleVerbatim: String, descriptionVerbatim: String?, isFirst: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.titleText = Text(titleVerbatim)
        self.descriptionText = descriptionVerbatim.map { Text($0) }
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
                    titleText.font(DS.Font.subheadline)
                    if let descriptionText {
                        descriptionText
                            .font(DS.Font.secondary)
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                }
                Spacer(minLength: 12)
                trailing
                    .toggleStyle(DSSwitchToggleStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

struct SettingHelper: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(DS.Font.secondary)
            .foregroundStyle(DS.Color.secondaryText)
            .padding(.horizontal, 4)
    }
}
