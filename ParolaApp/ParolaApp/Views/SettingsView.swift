import SwiftUI
import ParolaCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
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
        .axBranch("Settings")
    }
}

// MARK: - Routes

private enum SettingsRoute: String, CaseIterable, Identifiable, Hashable {
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
    var symbol: String { meta.symbol }
    var paneScope: SettingsPaneScope? { meta.scope }
}

private struct SettingsRouteMeta {
    let titleKey: String
    let symbol: String
    let scope: SettingsPaneScope?

    static let table: [SettingsRoute: SettingsRouteMeta] = [
        .general: SettingsRouteMeta(titleKey: "General", symbol: "gearshape", scope: .general),
        .customization: SettingsRouteMeta(titleKey: "Customization", symbol: "paintbrush", scope: .customization),
        .watchedFolders: SettingsRouteMeta(titleKey: "Watched Folders", symbol: "folder.badge.gearshape", scope: .watchedFolders),
        .recordMeetings: SettingsRouteMeta(titleKey: "Record Meetings", symbol: "video.bubble", scope: .recordMeetings),
        .shortcuts: SettingsRouteMeta(titleKey: "Shortcuts", symbol: "command", scope: nil),
        .microphone: SettingsRouteMeta(titleKey: "Microphone", symbol: "mic", scope: .microphone),
        .liveCaptions: SettingsRouteMeta(titleKey: "Live Captions", symbol: "captions.bubble", scope: .liveCaptions),
        .dictation: SettingsRouteMeta(titleKey: "Dictation", symbol: "text.bubble", scope: .dictation),
        .snippets: SettingsRouteMeta(titleKey: "Snippets", symbol: "text.append", scope: .snippets),
        .corrections: SettingsRouteMeta(titleKey: "Corrections", symbol: "wand.and.rays", scope: .corrections),
        .localModels: SettingsRouteMeta(titleKey: "Local Models", symbol: "cpu", scope: nil),
        .transcriptionDefaults: SettingsRouteMeta(titleKey: "Transcription Defaults", symbol: "slider.horizontal.3", scope: .transcriptionDefaults),
        .translation: SettingsRouteMeta(titleKey: "Translation", symbol: "character.book.closed", scope: .translation),
        .ignoredSegments: SettingsRouteMeta(titleKey: "Ignored Segments", symbol: "line.3.horizontal.decrease.circle", scope: .ignoredSegments),
        .findReplace: SettingsRouteMeta(titleKey: "Find & Replace", symbol: "arrow.triangle.2.circlepath", scope: .findReplace),
        .exportFormats: SettingsRouteMeta(titleKey: "Export Formats", symbol: "square.and.arrow.up", scope: .exportFormats),
        .batchExport: SettingsRouteMeta(titleKey: "Batch Export", symbol: "rectangle.stack.badge.play", scope: .batchExport),
        .autoExport: SettingsRouteMeta(titleKey: "Auto-Export", symbol: "arrow.up.doc", scope: .autoExport),
        .integrations: SettingsRouteMeta(titleKey: "Integrations", symbol: "puzzlepiece.extension", scope: .integrations),
        .prompts: SettingsRouteMeta(titleKey: "Prompts", symbol: "text.cursor", scope: .prompts),
        .automation: SettingsRouteMeta(titleKey: "MCP & Automation", symbol: "bolt.horizontal.circle", scope: .automation),
        .updates: SettingsRouteMeta(titleKey: "Updates", symbol: "arrow.down.circle", scope: .updates),
        .advanced: SettingsRouteMeta(titleKey: "Advanced", symbol: "wrench.and.screwdriver", scope: .advanced),
        .about: SettingsRouteMeta(titleKey: "About", symbol: "info.circle", scope: nil)
    ]
}

private struct SidebarGroup: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey?
    let routes: [SettingsRoute]
}

@MainActor
private var sidebarGroups: [SidebarGroup] {
    [
        SidebarGroup(title: nil, routes: [.general, .customization, .watchedFolders, .recordMeetings, .shortcuts]),
        SidebarGroup(title: "AUDIO & VIDEO", routes: [.microphone, .liveCaptions, .dictation, .snippets, .corrections]),
        SidebarGroup(title: "TRANSCRIPTION", routes: [.localModels, .transcriptionDefaults, .translation, .ignoredSegments, .findReplace]),
        SidebarGroup(title: "EXPORT", routes: [.exportFormats, .batchExport, .autoExport, .integrations]),
        SidebarGroup(title: "AI", routes: [.prompts]),
        SidebarGroup(title: "AUTOMATION", routes: [.automation, .updates]),
        SidebarGroup(title: nil, routes: [.advanced, .about])
    ]
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var route: SettingsRoute
    @Binding var search: String

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
                                .font(.caption.weight(.semibold))
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
            let hits = group.routes.filter { matches(route: $0, query: trimmed) }
            return hits.isEmpty ? nil : SidebarGroup(title: group.title, routes: hits)
        }
    }

    private func matches(route: SettingsRoute, query: String) -> Bool {
        if route.label.lowercased().contains(query) { return true }
        if let scope = route.paneScope {
            return scope.searchKeywords.contains { $0.lowercased().contains(query) }
        }
        return false
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
                    .font(.subheadline)
                    .frame(width: 16)
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                Text(route.localizedLabelKey)
                    .font(.subheadline)
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
        .axLeaf("Sidebar.Button.\(route.rawValue)")
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering = $0 }
        .accessibilityLabel(route.label)
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
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(route.localizedLabelKey)
                    .font(.title3.weight(.semibold))
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
                    titleText.font(.subheadline)
                    if let descriptionText {
                        descriptionText
                            .font(.caption)
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

struct SettingHelper: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(.caption)
            .italic()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }
}
