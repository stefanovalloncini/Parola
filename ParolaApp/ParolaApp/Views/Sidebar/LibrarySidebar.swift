import SwiftUI
import ParolaCore

/// A native sidebar list: places only, counts as badges, no footer.
struct LibrarySidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let people = sidebarPeople
        List(selection: selection(people: people)) {
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
            if model.sidebarShowsActivity {
                Section("Activity") {
                    Label("In Progress", systemImage: "hourglass")
                        .badge(model.activeBatchJobCount)
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

    /// Read from the model on every pass, so a page opened from a menu or the bridge moves the highlight too.
    private func selection(people: [Person]) -> Binding<SidebarItem?> {
        Binding(
            get: {
                SidebarSelection.current(
                    model.sidebarPage, sidebarPeople: people.map(\.id), showsActivity: model.sidebarShowsActivity
                )
            },
            set: { item in
                if let item { open(item) }
            }
        )
    }

    private func open(_ item: SidebarItem) {
        switch item {
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
