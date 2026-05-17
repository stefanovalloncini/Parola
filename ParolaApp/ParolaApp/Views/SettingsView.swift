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
    case automation
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
        case .automation: return "MCP & Automation"
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
        case .automation: return "bolt.horizontal.circle"
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
    SidebarGroup(title: "AUTOMATION", routes: [.automation]),
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
        case .localModels:
            ModelsSettingsPane()
        case .cloudModels:
            Text("Models pane — see Unit 5b").foregroundStyle(.secondary)
        case .people: PeoplePane()
        case .translation: TranslationPane()
        case .ignoredSegments: IgnoredSegmentsPane()
        case .findReplace: FindReplacePane()
        case .exportFormats: ExportFormatsPane()
        case .batchExport: BatchExportSettingsPane()
        case .autoExport: AutoExportPane()
        case .integrations: IntegrationsPane()
        case .services: ServicesPane()
        case .prompts: PromptsPane()
        case .automation: AutomationPane()
        case .advanced: AdvancedPane()
        case .about: AboutPane()
        }
    }
}

// MARK: - Section & row primitives

struct SettingsSection<Content: View>: View {
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

struct SettingRow<Trailing: View>: View {
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

struct SettingHelper: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .italic()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }
}
