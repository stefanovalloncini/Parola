import SwiftUI
import ParolaCore

extension EnvironmentValues {
    /// Test seam: run on each pass of a Library page header's body, so a test can tell what makes it run.
    @Entry var libraryHeaderPass: (@MainActor @Sendable () -> Void)?
}

/// The Library page's title and what it holds, with the menus that narrow and order the list.
struct LibraryPageHeader: View {
    /// A person only takes the title over an unset category; narrowed within one, the category keeps it.
    static func title(category: EntryCategory?, personName: String?) -> String {
        if let category { return String(localized: String.LocalizationValue(libraryCategoryName(category))) }
        return personName ?? String(localized: "Library")
    }

    /// Folds only when the row laid out unfolded, subtitle whole, is wider than the header; 0 is a row not measured yet.
    static func foldsFilters(unfoldedRowWidth: CGFloat, rowWidth: CGFloat) -> Bool {
        rowWidth > 0 && unfoldedRowWidth > rowWidth
    }

    /// Counts the rows on screen; empty while the first scan is out, or when the filters left none for No Matches to say.
    static func subtitle(
        count: Int, totalSeconds: Double, filteredOut: Bool = false, loaded: Bool = true, bundle: Bundle = .main
    ) -> String {
        guard count > 0 else { return filteredOut || !loaded ? "" : String(localized: "No transcripts yet", bundle: bundle) }
        return LibraryRowFormat.subtitle(count: count, totalSeconds: totalSeconds, bundle: bundle)
    }

    let title: String
    let subtitle: String
    let subtitleHelp: String?
    let filters: LibraryFilterBar
    /// An empty page has nothing to narrow or order; a filter already on stays so it can be cleared.
    let showsListControls: Bool
    /// Passed through unread, so a row click redraws the bulk actions and not the header around them.
    let selection: Binding<Set<LibraryEntry.ID>>
    @Binding var pendingBulkDelete: Bool

    // Optional: AppKit can build a List cell after SwiftUI tore the List down, and a required read traps "No Observable object of type AppModel found".
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.libraryHeaderPass) private var notePass
    @State private var rowWidth: CGFloat = 0
    @State private var unfoldedRowWidth: CGFloat = 0

    var body: some View {
        let _ = notePass?()
        VStack(alignment: .leading, spacing: DS.Spacing.hair) {
            Text(verbatim: title)
                .font(DS.Font.display)
                .tracking(DS.Tracking.display)
                .foregroundStyle(DS.Color.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            row(folded: Self.foldsFilters(unfoldedRowWidth: unfoldedRowWidth, rowWidth: rowWidth))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
                // An unfolded copy nobody sees or reaches, measured so the header knows before it would overflow.
                .background(alignment: .leading) {
                    row(folded: false)
                        .fixedSize()
                        .hidden()
                        .accessibilityHidden(true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { unfoldedRowWidth = $0 }
                }
        }
    }

    private func row(folded: Bool) -> some View {
        HStack(spacing: DS.Spacing.small) {
            Text(verbatim: subtitle)
                .font(DS.Font.secondary)
                .monospacedDigit()
                .foregroundStyle(DS.Color.secondaryText)
                .lineLimit(1)
                .modifier(OptionalHelp(help: subtitleHelp))
            Spacer(minLength: DS.Spacing.regular)
            controls(folded: folded)
        }
        .frame(minHeight: 22)
    }

    private var showsFilters: Bool {
        showsListControls || filters.isFiltering
    }

    @ViewBuilder
    private func controls(folded: Bool) -> some View {
        LibraryBulkActions(selection: selection, pendingBulkDelete: $pendingBulkDelete)
        if showsFilters, !folded {
            filters
        }
        if showsListControls, let model {
            sortMenu(model)
        }
        if showsFilters {
            moreMenu(folded: folded)
        }
    }

    private func sortMenu(_ model: AppModel) -> some View {
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
                .axLeaf("MenuItem.GroupByDate")
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .labelStyle(.titleAndIcon)
        .libraryHeaderChip()
        .help("Sort")
        .axLeaf("Menu.Sort")
    }

    /// Holds Language, and every filter once they fold; takes the chip's tint while filters wait inside it.
    private func moreMenu(folded: Bool) -> some View {
        let filtersInside = folded && filters.isFiltering
        let inside = filters.presented(as: folded ? .submenus : .language)
        return Menu {
            if folded || inside.showsLanguage {
                inside
                Divider()
            }
            Button { model?.openStatistics() } label: {
                Label("Statistics", systemImage: "chart.bar")
            }
            .axLeaf("MenuItem.Statistics")
            Button { model?.showingPeopleSheet = true } label: {
                Label("Manage People…", systemImage: "person.2")
            }
            .axLeaf("MenuItem.ManagePeople")
        } label: {
            // Set in a line of text, so the chip is as tall as the others.
            Text(Image(systemName: "ellipsis"))
        }
        .labelStyle(.titleAndIcon)
        .menuIndicator(.hidden)
        .libraryHeaderChip(isActive: filtersInside)
        .help("More")
        .accessibilityLabel("More")
        .accessibilityValue(filtersInside ? Text("Filters on") : Text(verbatim: ""))
        .axLeaf("Menu.More")
    }
}
