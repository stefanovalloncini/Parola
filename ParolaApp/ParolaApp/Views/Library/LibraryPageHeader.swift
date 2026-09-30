import SwiftUI
import ParolaCore

/// The Library page's title and what it holds, with the menus that narrow and order the list.
struct LibraryPageHeader: View {
    static let foldWidth: CGFloat = 1000

    /// A person only takes the title over an unset category; narrowed within one, the category keeps it.
    static func title(category: EntryCategory?, personName: String?) -> String {
        if let category { return String(localized: String.LocalizationValue(libraryCategoryName(category))) }
        return personName ?? String(localized: "Library")
    }

    /// Read off the window rather than measured from the menus, which change width as filters come and go.
    static func foldsFilters(windowWidth: CGFloat) -> Bool {
        windowWidth < foldWidth
    }

    static func subtitle(count: Int, totalSeconds: Double, bundle: Bundle = .main) -> String {
        guard count > 0 else { return String(localized: "No transcripts yet", bundle: bundle) }
        return LibraryRowFormat.subtitle(count: count, totalSeconds: totalSeconds, bundle: bundle)
    }

    let title: String
    let subtitle: String
    let subtitleHelp: String?
    let filters: LibraryFilterBar
    /// An empty page has nothing to narrow or order; a filter already on stays so it can be cleared.
    let showsListControls: Bool
    let selection: Set<LibraryEntry.ID>
    @Binding var pendingBulkDelete: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.mainWindowWidth) private var windowWidth

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.hair) {
            Text(verbatim: title)
                .font(DS.Font.display)
                .tracking(DS.Tracking.display)
                .foregroundStyle(DS.Color.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: DS.Spacing.regular) {
                Text(verbatim: subtitle)
                    .font(DS.Font.secondary)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(1)
                    .modifier(OptionalHelp(help: subtitleHelp))
                Spacer(minLength: DS.Spacing.regular)
                controls
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        let folds = Self.foldsFilters(windowWidth: windowWidth)
        let showsFilters = showsListControls || filters.isFiltering
        LibraryBulkActions(selection: selection, pendingBulkDelete: $pendingBulkDelete)
        if showsFilters, !folds {
            filters
        }
        if showsListControls {
            sortMenu
        }
        moreMenu(foldedFilters: showsFilters && folds)
    }

    private var sortMenu: some View {
        @Bindable var model = model
        return Menu {
            Picker("Sort", selection: $model.librarySortOrder) {
                ForEach(LibrarySortOrder.allCases) { order in
                    Text(LocalizedStringKey(order.label)).tag(order)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Group by Date", isOn: $model.libraryGroupsByDate)
                .disabled(!model.librarySortOrder.isChronological)
                .axLeaf("Library.MenuItem.GroupByDate")
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .labelStyle(.titleAndIcon)
        .libraryHeaderMenu()
        .help("Sort")
        .axLeaf("Library.Menu.Sort")
    }

    /// Drawn in SwiftUI, not handed to AppKit like the text menus: AppKit would drop the glyph's spoken name.
    private func moreMenu(foldedFilters: Bool) -> some View {
        let filtersInside = foldedFilters && filters.isFiltering
        return Menu {
            if foldedFilters {
                filters
                Divider()
            }
            Button { model.openStatistics() } label: {
                Label("Statistics", systemImage: "chart.bar")
            }
            .axLeaf("Library.MenuItem.Statistics")
            Button { model.showingPeopleSheet = true } label: {
                Label("Manage People…", systemImage: "person.2")
            }
            .axLeaf("Library.MenuItem.ManagePeople")
        } label: {
            Image(systemName: filtersInside ? "ellipsis.circle.fill" : "ellipsis.circle")
        }
        .labelStyle(.titleAndIcon)
        .menuStyle(.button)
        .buttonStyle(GlyphButtonStyle(tinted: filtersInside))
        .tint(DS.Color.accentInk)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
        .axLeaf("Library.Menu.More")
    }
}
