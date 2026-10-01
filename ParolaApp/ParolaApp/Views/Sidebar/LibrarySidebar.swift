import SwiftUI
import ParolaCore

/// A native sidebar list: places only, counts as badges.
struct LibrarySidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let people = sidebarPeople
        List(selection: selection(people: people)) {
            if model.stageHoldsTake {
                Section {
                    SidebarRecordingRow(isSelected: current(people: people.map(\.id)) == .recording)
                        .axLeaf("Row.Recording")
                }
            }
            Section {
                Label("Library", systemImage: "books.vertical")
                    .badge(model.libraryCounts.total)
                    .tag(SidebarItem.library)
                    .axLeaf("Row.Library")
                ForEach(categories, id: \.self) { category in
                    Label(LocalizedStringKey(libraryCategoryName(category)), systemImage: DS.categorySymbol(for: category))
                        .badge(model.libraryCounts.count(of: category))
                        .tag(SidebarItem.category(category))
                        .axLeaf("Row.\(libraryCategoryName(category))")
                }
            }
            if !people.isEmpty {
                PeopleSidebarSection(people: people)
            }
            if let activity = model.sidebarActivity {
                Section("Activity") {
                    Label(LocalizedStringKey(activity.title), systemImage: activity.systemImage)
                        .badge(activity.count)
                        .tag(SidebarItem.activity)
                        .axLeaf("Row.Activity")
                }
            }
            if let store = model.watchedFoldersIfWatching {
                UnavailableWatchedFolders(store: store)
            }
            Section {
                Label("Recently Deleted", systemImage: "trash")
                    .badge(model.deletedEntries.count)
                    .tag(SidebarItem.recentlyDeleted)
                    .axLeaf("Row.RecentlyDeleted")
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(
            min: MainWindowLayout.sidebarMinWidth,
            ideal: MainWindowLayout.sidebarIdealWidth,
            max: MainWindowLayout.sidebarMaxWidth
        )
        .axBranch("Sidebar")
    }

    /// Read from the model on every pass, so a page opened from a menu or the bridge moves the highlight too; the Recording row lights itself.
    private func selection(people: [Person]) -> Binding<SidebarItem?> {
        let ids = people.map(\.id)
        return Binding(
            get: {
                _ = model.sidebarRefusedPicks
                let item = current(people: ids)
                return item == .recording ? nil : item
            },
            set: { item in
                guard let item else { return }
                open(item)
                Task { await letGoIfRefused(item, people: ids) }
            }
        )
    }

    private func current(people: [UUID]) -> SidebarItem? {
        SidebarSelection.current(
            model.sidebarPage,
            sidebarPeople: people,
            showsActivity: model.sidebarShowsActivity,
            showsRecording: model.stageHoldsTake
        )
    }

    /// Checked once the transcript a pick closes is gone, so a page that does open never blinks its row.
    private func letGoIfRefused(_ item: SidebarItem, people: [UUID]) async {
        await model.awaitTranscriptClose()
        if current(people: people) != item { model.sidebarRefusedPicks &+= 1 }
    }

    private func open(_ item: SidebarItem) {
        switch item {
        case .recording: model.showStage()
        case .library: model.goHome()
        case .category(let category): model.browseCategory(category)
        case .person(let id): model.browsePerson(id)
        case .activity: model.openQueue()
        case .recentlyDeleted: model.openRecentlyDeleted()
        }
    }

    private var categories: [EntryCategory] {
        var rows: [EntryCategory] = [.transcription]
        if model.features.isEnabled(.meetings) { rows.append(.meeting) }
        if model.features.isEnabled(.dictation) { rows.append(.dictation) }
        return rows
    }

    private var sidebarPeople: [Person] {
        guard PeopleSidebarSection.isVisible(showMostUsed: model.showMostUsedPeople, people: model.people) else {
            return []
        }
        return model.mostUsedPeople(limit: PeopleSidebarSection.rowLimit)
    }
}
