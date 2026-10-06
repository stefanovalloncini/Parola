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
    case localModels, transcriptionDefaults, translation, people, ignoredSegments, findReplace
    case exportFormats, batchExport, autoExport, sendTo, integrations
    case aiServices, prompts
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
        .customization: SettingsRouteMeta(titleKey: "Customization", summaryKey: "Appearance, theme colors and timestamp font.", symbol: "paintbrush", scope: .customization),
        .watchedFolders: SettingsRouteMeta(titleKey: "Watched Folders", summaryKey: "Folders Parola watches, so anything dropped in is transcribed on its own.", symbol: "folder.badge.gearshape", scope: .watchedFolders),
        .recordMeetings: SettingsRouteMeta(titleKey: "Record Meetings", summaryKey: "Recording meeting audio, and what Parola does when a meeting app starts.", symbol: "video.bubble", scope: .recordMeetings),
        .shortcuts: SettingsRouteMeta(titleKey: "Shortcuts", summaryKey: "The dictation and recording shortcuts that work from any app.", symbol: "command", scope: .shortcuts),
        .microphone: SettingsRouteMeta(titleKey: "Microphone", summaryKey: "Which input Parola records from, and what happens while recording.", symbol: "mic", scope: .microphone),
        .liveCaptions: SettingsRouteMeta(titleKey: "Live Captions", summaryKey: "Live transcription of what you hear, in a floating window.", symbol: "captions.bubble", scope: .liveCaptions),
        .dictation: SettingsRouteMeta(titleKey: "Dictation", summaryKey: "The hotkey that turns speech into text in any app.", symbol: "text.bubble", scope: .dictation),
        .snippets: SettingsRouteMeta(titleKey: "Snippets", summaryKey: "Short triggers that expand into longer text while you dictate.", symbol: "text.append", scope: .snippets),
        .corrections: SettingsRouteMeta(titleKey: "Corrections", summaryKey: "Word replacements applied to dictated text after each take.", symbol: "wand.and.rays", scope: .corrections),
        .localModels: SettingsRouteMeta(titleKey: "Local Models", summaryKey: "Speech models on this Mac, and the space they take up.", symbol: "cpu", scope: nil),
        .transcriptionDefaults: SettingsRouteMeta(titleKey: "Transcription Defaults", summaryKey: "The model and language new transcriptions start with.", symbol: "slider.horizontal.3", scope: .transcriptionDefaults),
        .translation: SettingsRouteMeta(titleKey: "Translation", summaryKey: "How Parola translates a transcript, and how it shows the result.", symbol: "character.book.closed", scope: .translation),
        .people: SettingsRouteMeta(titleKey: "People", summaryKey: "The speakers you name, the colour each one wears, and where they show up.", symbol: "person.2", scope: .people),
        .ignoredSegments: SettingsRouteMeta(titleKey: "Ignored Segments", summaryKey: "Segments dropped from a transcript when the text matches a pattern.", symbol: "line.3.horizontal.decrease.circle", scope: .ignoredSegments),
        .findReplace: SettingsRouteMeta(titleKey: "Find & Replace", summaryKey: "Substitutions applied to every transcript before it's saved.", symbol: "arrow.triangle.2.circlepath", scope: .findReplace),
        .exportFormats: SettingsRouteMeta(titleKey: "Export Formats", summaryKey: "The named exports Parola can write, and what each one puts in the file.", symbol: "square.and.arrow.up", scope: .exportFormats),
        .batchExport: SettingsRouteMeta(titleKey: "Batch Export", summaryKey: "What happens to files exported from a batch run.", symbol: "rectangle.stack.badge.play", scope: .batchExport),
        .autoExport: SettingsRouteMeta(titleKey: "Auto-Export", summaryKey: "Rules that write a transcript to disk as soon as it's ready.", symbol: "arrow.up.doc", scope: .autoExport),
        .sendTo: SettingsRouteMeta(titleKey: "Send To", summaryKey: "Where a finished transcript is sent, starting with a folder in your Obsidian vault.", symbol: "paperplane", scope: .sendTo),
        .integrations: SettingsRouteMeta(titleKey: "Integrations", summaryKey: "Helper tools Parola uses to fetch audio from links.", symbol: "puzzlepiece.extension", scope: .integrations),
        .aiServices: SettingsRouteMeta(titleKey: "AI Services", summaryKey: "Which model answers each AI task: Apple Intelligence on this Mac, or a service you configure.", symbol: "sparkles", scope: .aiServices),
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
            SidebarGroup(id: "transcription", title: "TRANSCRIPTION", routes: [.localModels, .transcriptionDefaults, .translation, .people, .ignoredSegments, .findReplace]),
            SidebarGroup(id: "export", title: "EXPORT", routes: [.exportFormats, .batchExport, .autoExport, .sendTo]),
            SidebarGroup(id: "ai", title: "AI", routes: [.aiServices, .prompts]),
            SidebarGroup(id: "automation", title: "AUTOMATION", routes: [.automation]),
            SidebarGroup(id: "end", title: "SUPPORT", routes: [.advanced, .about])
        ]
    }

    static func visibleGroups(features: FeatureSet, search: String) -> [SidebarGroup] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return all.compactMap { group in
            let routes = group.routes.filter { route in
                route.isVisible(features: features) && (query.isEmpty || matches(route: route, query: query, features: features))
            }
            return routes.isEmpty ? nil : SidebarGroup(id: group.id, title: group.title, routes: routes)
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
    @Binding var route: SettingsRoute
    @Binding var search: String
    let features: FeatureSet
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            SearchPill(text: $search, placeholder: "Search Settings…", leaf: "Sidebar.TextField.Search")
                .padding(.horizontal, DS.Spacing.regular)
                .padding(.top, DS.Spacing.regular)
                .padding(.bottom, DS.Spacing.small)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(filteredGroups) { group in
                        if let title = group.title {
                            SectionCaption(title)
                                .padding(.horizontal, DS.Spacing.medium)
                                .padding(.top, DS.Spacing.tight)
                        }
                        VStack(spacing: 2) {
                            ForEach(group.routes) { r in
                                SidebarRow(
                                    title: r.localizedLabelKey,
                                    systemImage: r.symbol,
                                    isSelected: route == r,
                                    height: 28,
                                    iconTint: DS.settingsGroupTint(for: group.id)
                                ) {
                                    route = r
                                }
                                .axLeaf("Sidebar.Button.\(r.rawValue)")
                                .accessibilityLabel(r.label)
                                .padding(.horizontal, DS.Spacing.small)
                            }
                        }
                    }
                }
                .padding(.bottom, DS.Spacing.medium)
                .id(model.themeRevision)
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
                        .font(DS.Font.heading)
                    Text(route.localizedSummaryKey)
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, DS.Spacing.medium)
                content
                Spacer(minLength: 24)
            }
            .padding(.horizontal, DS.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(model.themeRevision)
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
                    .padding(.bottom, DS.Spacing.hair)
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
    @Namespace private var pair

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
                Divider().padding(.leading, DS.Spacing.medium)
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    titleText
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.primaryText)
                        .accessibilityLabeledPair(role: .label, id: "row", in: pair)
                    if let descriptionText {
                        descriptionText
                            .font(DS.Font.secondary)
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                }
                Spacer(minLength: 12)
                trailing
                    .toggleStyle(DSSwitchToggleStyle())
                    .accessibilityLabeledPair(role: .content, id: "row", in: pair)
            }
            .padding(.horizontal, DS.Spacing.medium)
            .padding(.vertical, DS.Spacing.small)
        }
    }
}

struct SettingHelper: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(DS.Font.secondary)
            .foregroundStyle(DS.Color.secondaryText)
            .padding(.horizontal, DS.Spacing.tight)
    }
}
