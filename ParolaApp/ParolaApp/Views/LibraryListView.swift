import AppKit
import SwiftUI
import ParolaCore

enum LibraryEmptyAction {
    case openFile
    case recordMicrophone
    case recordSystemAudio
    case startDictation
    case meetingSettings
    case dictationSettings
}

/// What an emptied list shows: the page's own empty state when it holds nothing, Clear Filters when the filters hid it all.
enum LibraryEmptyState {
    enum Kind {
        case none
        case emptyLibrary
        case noMatches
    }

    /// Nothing is empty before the first scan lands; `entryCount` is the page before any filter, so Clear Filters needs one on.
    static func kind(entryCount: Int, visibleCount: Int, filtersActive: Bool, loaded: Bool = true) -> Kind {
        guard loaded else { return .none }
        if entryCount == 0 { return .emptyLibrary }
        return visibleCount == 0 && filtersActive ? .noMatches : .none
    }

    /// The page's category, or the whole library: a person narrows a page like any other filter.
    static func entryCount(in entries: [LibraryEntry], category: EntryCategory?) -> Int {
        guard let category else { return entries.count }
        return entries.count(where: { $0.category == category })
    }

    /// True when filters hid every row of a page that holds transcripts, so the subtitle leaves the line to No Matches.
    static func filtersEmptied(_ kind: Kind, pageCount: Int) -> Bool {
        kind == .noMatches && pageCount > 0
    }

    /// The hero belongs to the Library page itself; a category or a person over an empty library keeps its own empty state.
    static func showsHero(_ kind: Kind, category: EntryCategory?, person: UUID?) -> Bool {
        kind == .emptyLibrary && category == nil && person == nil
    }
}

enum LibraryListContent {
    /// Leads with the action that produces the kind of entry the category holds, then the fallbacks.
    static func emptyActions(for category: EntryCategory, features: FeatureSet) -> [LibraryEmptyAction] {
        var actions: [LibraryEmptyAction] = []
        if category == .meeting, features.isEnabled(.meetings) { actions.append(.recordSystemAudio) }
        if category == .dictation, features.isEnabled(.dictation) { actions.append(.startDictation) }
        actions.append(.openFile)
        if category == .transcription, features.isEnabled(.micRecording) { actions.append(.recordMicrophone) }
        if category == .meeting, features.isEnabled(.meetings) { actions.append(.meetingSettings) }
        if category == .dictation, features.isEnabled(.dictation) { actions.append(.dictationSettings) }
        return actions
    }

    /// The source keys, not `LocalizedStringKey`, so the casing rule can be asserted over them.
    static func emptyTitle(for category: EntryCategory) -> String {
        switch category {
        case .transcription: return "No Transcriptions Yet"
        case .meeting: return "No Meetings Yet"
        case .dictation: return "No Dictations Yet"
        }
    }

    /// Shown instead of `emptyTitle` when the category has rows and the filters are what hid them.
    static let filteredEmptyTitle = "No Matches for This Filter"

    struct PageTotals: Equatable {
        var count = 0
        var seconds: Double = 0
        var bytes: Int64 = 0
    }

    /// The header counts what the filters leave on screen, so its numbers always match the rows under it.
    static func totals(of shown: [LibraryEntry], sizes: [String: Int64]) -> PageTotals {
        var totals = PageTotals()
        for entry in shown {
            totals.count += 1
            totals.seconds += entry.durationSeconds ?? 0
            totals.bytes += sizes[entry.id] ?? 0
        }
        return totals
    }

    /// What the page holds before its filters: a category, else a person's own page, else the library.
    static func pageCount(of entries: [LibraryEntry], category: EntryCategory?, person: UUID?) -> Int {
        let pagePerson = category == nil ? person : nil
        return entries.count { entry in
            if let category, entry.category != category { return false }
            if let pagePerson, !entry.assigns(personID: pagePerson) { return false }
            return true
        }
    }

    /// A browse list sits under the results only when clearing the query would show it: not over a transcript.
    static func showsBrowseList(hasTranscript: Bool) -> Bool {
        !hasTranscript
    }

    /// What Clear Filters resets: every dimension the list can be narrowed by, including the person.
    static func clearFilters(
        labelFilter: inout String?,
        languageFilter: inout String?,
        dateRangeFilter: inout LibraryDateRangeFilter,
        personFilter: inout UUID?
    ) {
        labelFilter = nil
        languageFilter = nil
        dateRangeFilter = .all
        personFilter = nil
    }

    struct ActiveFilters: Equatable {
        var label: String? = nil
        var language: String? = nil
        var dateRange: LibraryDateRangeFilter = .all
        var person: UUID? = nil

        var isEmpty: Bool { label == nil && language == nil && dateRange == .all && person == nil }
    }

    /// Filters survive a category switch, but one the new category has no row for is dropped, not carried over empty.
    static func filters(
        _ active: ActiveFilters,
        survivingIn category: EntryCategory?,
        entries: [LibraryEntry]
    ) -> ActiveFilters {
        func matchesSomething(
            label: String? = nil,
            language: String? = nil,
            dateRange: LibraryDateRangeFilter = .all,
            person: UUID? = nil
        ) -> Bool {
            anyRow(
                in: entries, category: category, labelFilter: label, languageFilter: language,
                dateRange: dateRange, personFilter: person
            )
        }
        var kept = active
        if kept.label != nil, !matchesSomething(label: kept.label) { kept.label = nil }
        if kept.language != nil, !matchesSomething(language: kept.language) { kept.language = nil }
        if kept.person != nil, !matchesSomething(person: kept.person) { kept.person = nil }
        if kept.dateRange != .all,
           !matchesSomething(label: kept.label, language: kept.language, dateRange: kept.dateRange, person: kept.person) {
            kept.dateRange = .all
        }
        return kept
    }

    /// The same test `rows` applies, without building the array a caller only measures for emptiness.
    private static func anyRow(
        in entries: [LibraryEntry],
        category: EntryCategory?,
        labelFilter: String?,
        languageFilter: String?,
        dateRange: LibraryDateRangeFilter,
        personFilter: UUID?
    ) -> Bool {
        let cutoff = dateRange.cutoff
        return entries.contains {
            matches(
                $0, category: category, labelFilter: labelFilter, languageFilter: languageFilter,
                cutoff: cutoff, personFilter: personFilter
            )
        }
    }

    private static func matches(
        _ entry: LibraryEntry,
        category: EntryCategory?,
        labelFilter: String?,
        languageFilter: String?,
        cutoff: Date?,
        personFilter: UUID?
    ) -> Bool {
        if let category, entry.category != category { return false }
        if let personFilter, !entry.assigns(personID: personFilter) { return false }
        if let labelFilter,
           !entry.labels.contains(where: { $0.localizedCaseInsensitiveCompare(labelFilter) == .orderedSame }) {
            return false
        }
        if let languageFilter, LanguageDisplay.code(for: entry.language) != languageFilter { return false }
        if let cutoff, entry.createdAt < cutoff { return false }
        return true
    }

    static func totalsLabel(
        for count: Int,
        bundle: Bundle = .main,
        locale: Locale = AppFormat.locale
    ) -> String? {
        guard count > 0 else { return nil }
        if count == 1 { return String(localized: "1 transcript", bundle: bundle, locale: locale) }
        return String(localized: "\(count) transcripts", bundle: bundle, locale: locale)
    }

    /// The search page counts two things: the entries that matched, and the hits they hold between them.
    static func searchTotalsLabel(
        entries: Int,
        matches: Int,
        locale: Locale = AppFormat.locale
    ) -> String? {
        guard let transcripts = totalsLabel(for: entries, locale: locale) else { return nil }
        guard matches > 0 else { return transcripts }
        return "\(transcripts) · \(matchesLabel(matches, locale: locale))"
    }

    /// The rows keep a column for the time so their snippets line up; a list where nothing was spoken keeps its width.
    static func showsTimestampSlot(
        for ids: [LibraryEntry.ID],
        matches: [String: LibrarySearchIndex.Match]
    ) -> Bool {
        ids.contains { matches[$0]?.firstHit != nil }
    }

    /// Reads the counts live: a query edit can leave the same entries matching a different number of times.
    static func searchTotalsLabel(
        for ids: [LibraryEntry.ID],
        matches: [String: LibrarySearchIndex.Match],
        locale: Locale = AppFormat.locale
    ) -> String? {
        searchTotalsLabel(
            entries: ids.count,
            matches: ids.reduce(0) { $0 + (matches[$1]?.matchCount ?? 0) },
            locale: locale
        )
    }

    static func matchesLabel(_ count: Int, locale: Locale = AppFormat.locale) -> String {
        if count == 1 { return String(localized: "1 match", locale: locale) }
        return String(localized: "\(count) matches", locale: locale)
    }

    static func rows(
        from entries: [LibraryEntry],
        category: EntryCategory?,
        labelFilter: String?,
        languageFilter: String?,
        dateRange: LibraryDateRangeFilter,
        personFilter: UUID?
    ) -> [LibraryEntry] {
        let cutoff = dateRange.cutoff
        let filtered = entries.filter {
            matches(
                $0, category: category, labelFilter: labelFilter, languageFilter: languageFilter,
                cutoff: cutoff, personFilter: personFilter
            )
        }
        // The entries arrive in the order the Sort menu picked; only pinning is layered on top.
        return filtered.filter(\.pinned) + filtered.filter { !$0.pinned }
    }

    struct OpenRequest: Equatable {
        let id: LibraryEntry.ID
        let inNewWindow: Bool
    }

    /// Double-click and Return open the one row they land on, in its own window with Option; several rows open nothing.
    static func openRequest(for ids: Set<LibraryEntry.ID>, modifiers: NSEvent.ModifierFlags) -> OpenRequest? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return OpenRequest(id: id, inNewWindow: modifiers.contains(.option))
    }
}

/// The library's content area: the browse list, with a query's results laid over it while one is open.
struct LibraryListView: View {
    let category: EntryCategory?
    /// Whether clearing the query would show a browse list; a loaded transcript has none under its results.
    let browses: Bool
    let searchRanking: [LibraryEntry.ID]?

    /// Built the first time it would show, then kept up behind any results, so a query never re-diffs its rows.
    @State private var browseMounted = false
    @FocusState private var focus: LibraryListFocus?

    private var searching: Bool { searchRanking != nil }

    var body: some View {
        ZStack {
            if browseMounted {
                LibraryBrowseList(category: category, focus: $focus)
                    .equatable()
                    .opacity(searching ? 0 : 1)
                    .allowsHitTesting(!searching)
                    .accessibilityHidden(searching)
            }
            if let searchRanking {
                LibrarySearchResults(ranking: searchRanking, focus: $focus)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { syncBrowseMount() }
        .onChange(of: browses) { _, _ in syncBrowseMount() }
        .onChange(of: searching) { _, _ in
            syncBrowseMount()
            // The list with the keyboard hands it to the one taking its place.
            switch focus {
            case .browse? where searching: focus = resultsTakeFocus ? .results : nil
            case .results? where !searching: focus = .browse
            default: break
            }
        }
        // The covered list stays in the key view loop, so Tab can still land on it; the keyboard moves past it.
        .onChange(of: focus) { old, new in
            guard searching, new == .browse else { return }
            focus = old != .results && resultsTakeFocus ? .results : nil
        }
        .axBranch("Library")
    }

    private var resultsTakeFocus: Bool {
        !(searchRanking?.isEmpty ?? true)
    }

    private func syncBrowseMount() {
        if !browses {
            browseMounted = false
        } else if !searching {
            browseMounted = true
        }
    }
}

/// A category's rows, or all of them, with the filters and the date groups.
private struct LibraryBrowseList: View, Equatable {
    @Environment(AppModel.self) private var model
    let category: EntryCategory?
    let focus: FocusState<LibraryListFocus?>.Binding

    /// The focus binding is left out: it never changes, and comparing it would re-run this body on every keystroke.
    nonisolated static func == (lhs: LibraryBrowseList, rhs: LibraryBrowseList) -> Bool {
        lhs.category == rhs.category
    }

    @State private var selection: Set<LibraryEntry.ID> = []
    @State private var pendingBulkDelete = false
    @State private var renamingEntry: LibraryEntry?
    @State private var renameDraft: String = ""
    @State private var labelFilter: String?
    @State private var languageFilter: String?
    @State private var dateRangeFilter: LibraryDateRangeFilter = .all
    @State private var rowItems: [LibraryListItem] = []
    @State private var shownTotals = LibraryListContent.PageTotals()
    @State private var pageCount = 0
    /// Set with `rowItems`, from the same library and filters, so no pass judges new filters against rows not yet rebuilt.
    @State private var emptyKind = LibraryEmptyState.Kind.none
    @State private var showsHero = false
    @State private var libraryLoaded = false
    @State private var displayCache = LibraryRowDisplayCache()
    @State private var animatesRows = false

    private var activeFilters: LibraryListContent.ActiveFilters {
        LibraryListContent.ActiveFilters(
            label: labelFilter, language: languageFilter, dateRange: dateRangeFilter, person: model.personFilter
        )
    }

    /// Narrows the category on screen; unlike a sidebar or bridge pick it never navigates.
    private var personFilterBinding: Binding<UUID?> {
        Binding(get: { model.personFilter }, set: { model.personFilter = $0 })
    }

    @discardableResult
    private func recomputeEntries() -> [LibraryRowDisplay] {
        recomputeEntries(with: activeFilters)
    }

    /// Takes filters explicitly so a category switch can recompute with the ones it just dropped, not `@State` it just wrote.
    @discardableResult
    private func recomputeEntries(with filters: LibraryListContent.ActiveFilters) -> [LibraryRowDisplay] {
        let computed = LibraryListContent.rows(
            from: model.libraryEntries,
            category: category,
            labelFilter: filters.label,
            languageFilter: filters.language,
            dateRange: filters.dateRange,
            personFilter: filters.person
        )
        var cache = displayCache
        cache.prune(keeping: model.libraryEntries.lazy.map(\.id))
        let headers = LibraryDateGroups.Headers(sortOrder: model.librarySortOrder, groupsByDate: model.libraryGroupsByDate)
        let usualLanguage = model.usualLanguage
        let displays = computed.map { entry -> LibraryRowDisplay in
            cache.display(
                for: entry, excerpt: model.libraryExcerpts[entry.id],
                when: headers.when(for: entry), usualLanguage: usualLanguage,
                showsAITitle: model.showAITitles, showsAISummary: model.showAISummaries
            )
        }
        displayCache = cache
        rowItems = LibraryListItem.items(for: headers.groups(for: displays))
        shownTotals = LibraryListContent.totals(of: computed, sizes: model.libraryBundleSizes)
        pageCount = LibraryListContent.pageCount(of: model.libraryEntries, category: category, person: filters.person)
        libraryLoaded = model.libraryLoaded
        emptyKind = LibraryEmptyState.kind(
            entryCount: LibraryEmptyState.entryCount(in: model.libraryEntries, category: category),
            visibleCount: displays.count,
            filtersActive: !filters.isEmpty,
            loaded: libraryLoaded
        )
        showsHero = LibraryEmptyState.showsHero(emptyKind, category: category, person: filters.person)
        return displays
    }

    var body: some View {
        Group {
            if emptyKind == .none {
                ScrollViewReader { proxy in
                    LibraryRowList(
                        items: rowItems,
                        selection: $selection,
                        detail: .excerpt,
                        animatesRows: animatesRows,
                        rename: { entry in
                            renameDraft = LibraryEntryDisplay.listTitle(for: entry, showsAITitle: model.showAITitles)
                            renamingEntry = entry
                        },
                        focus: focus,
                        focusKey: .browse,
                        top: pageTop(showsIntake: true)
                            .padding(.top, DS.Spacing.small)
                            .padding(.bottom, DS.Spacing.tight)
                    )
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .background { FailureScroll(proxy: proxy) }
                }
            } else {
                VStack(spacing: 0) {
                    pageTop(showsIntake: !showsHero)
                        .padding(.horizontal, DS.Spacing.large)
                        .padding(.top, DS.Spacing.medium)
                    emptyContent
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { recomputeEntries() }
        // Later than onAppear's first fill, so the rows the route opens with don't animate in.
        .task { animatesRows = true }
        .onChange(of: model.libraryVersion) { _, _ in
            let newEntries = recomputeEntries()
            selection = selection.intersection(Set(newEntries.map(\.id)))
        }
        .onChange(of: labelFilter) { _, _ in recomputeEntries() }
        .onChange(of: languageFilter) { _, _ in recomputeEntries() }
        .onChange(of: dateRangeFilter) { _, _ in recomputeEntries() }
        .onChange(of: model.personFilter) { _, _ in recomputeEntries() }
        .onChange(of: model.libraryBundleSizesVersion) { _, _ in recomputeEntries() }
        .onChange(of: model.libraryExcerptsVersion) { _, _ in recomputeEntries() }
        .onChange(of: model.libraryGroupsByDate) { _, _ in recomputeEntries() }
        // An empty library's first scan lands no entries, so only this says it has looked.
        .onChange(of: model.libraryLoaded) { _, _ in recomputeEntries() }
        .onChange(of: category) { _, newCategory in
            // Navigation owns personFilter now; this only decides what to keep for label/language/date.
            var kept = LibraryListContent.filters(
                activeFilters,
                survivingIn: newCategory,
                entries: model.libraryEntries
            )
            kept.person = activeFilters.person
            labelFilter = kept.label
            languageFilter = kept.language
            dateRangeFilter = kept.dateRange
            let newEntries = recomputeEntries(with: kept)
            selection = selection.intersection(Set(newEntries.map(\.id)))
        }
        // Headers and row times are written when the groups are built, so midnight has to rewrite them.
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            recomputeEntries()
        }
        // The one input no entry carries, so no row notices it changed on its own.
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            displayCache.removeAll()
            recomputeEntries()
        }
        .modifier(LibraryListAlerts(
            selection: $selection,
            pendingBulkDelete: $pendingBulkDelete,
            renamingEntry: $renamingEntry,
            renameDraft: $renameDraft
        ))
    }

    @ViewBuilder
    private var emptyContent: some View {
        if showsHero {
            heroState
        } else if emptyKind == .emptyLibrary, let category {
            emptyState(of: category)
        } else {
            noMatchesState
        }
    }

    /// The hero on an empty library says what the intake strip would, so the strip stands aside for it.
    private func pageTop(showsIntake: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            LibraryPageHeader(
                title: LibraryPageHeader.title(category: category, personName: selectedPerson?.name),
                subtitle: LibraryPageHeader.subtitle(
                    count: shownTotals.count,
                    totalSeconds: shownTotals.seconds,
                    filteredOut: LibraryEmptyState.filtersEmptied(emptyKind, pageCount: pageCount),
                    loaded: libraryLoaded
                ),
                subtitleHelp: shownTotals.bytes > 0
                    ? String(localized: "Total size: \(AppFormat.byteSize(shownTotals.bytes))") : nil,
                filters: LibraryFilterBar(
                    labelFilter: $labelFilter,
                    languageFilter: $languageFilter,
                    dateRangeFilter: $dateRangeFilter,
                    personFilter: personFilterBinding,
                    labelOptions: model.knownLabels(in: category),
                    languageOptions: model.knownLanguages(in: category),
                    peopleOptions: model.knownPeople(in: category)
                ),
                showsListControls: pageCount > 0,
                selection: selection,
                pendingBulkDelete: $pendingBulkDelete
            )
            if showsIntake {
                IntakeStrip()
            }
            LibraryFailureBanner()
        }
    }

    private var heroState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: DS.Spacing.large)
            EmptyLibraryHero()
            Spacer(minLength: DS.Spacing.large)
        }
        .padding(.horizontal, DS.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(of category: EntryCategory) -> some View {
        EmptyStateView(
            systemImage: DS.categorySymbol(for: category),
            title: LocalizedStringKey(LibraryListContent.emptyTitle(for: category))
        ) {
            let actions = LibraryListContent.emptyActions(for: category, features: model.features)
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                Button {
                    perform(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .buttonStyle(DSPillButtonStyle(kind: index == 0 ? .primary : .secondary))
                .axLeaf(action.axLeaf)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .axBranch("Empty")
    }

    /// The filters (a person's page counts) are what emptied it. Offering "Record" here would be a lie.
    private var noMatchesState: some View {
        EmptyStateView(
            systemImage: "line.3.horizontal.decrease.circle",
            title: LocalizedStringKey(LibraryListContent.filteredEmptyTitle)
        ) {
            Button {
                LibraryListContent.clearFilters(
                    labelFilter: &labelFilter,
                    languageFilter: &languageFilter,
                    dateRangeFilter: &dateRangeFilter,
                    personFilter: &model.personFilter
                )
            } label: {
                Label("Clear Filters", systemImage: "xmark.circle")
            }
            .buttonStyle(DSPillButtonStyle(kind: .primary))
            .axLeaf("ClearFilters")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .axBranch("Empty")
    }

    private func perform(_ action: LibraryEmptyAction) {
        switch action {
        case .openFile: model.presentOpenPanel()
        case .recordMicrophone: model.startRecording(source: .microphone)
        case .recordSystemAudio: model.startRecording(source: .systemAudio)
        case .startDictation: model.startDictationFromIntent()
        case .meetingSettings: model.openSettings(route: .recordMeetings)
        case .dictationSettings: model.openSettings(route: .dictation)
        }
    }

    private var selectedPerson: Person? {
        model.personFilter.flatMap(model.person(id:))
    }
}

/// Its own view, so a phase change repaints the banner and never the rows under it.
struct LibraryFailureBanner: View {
    @Environment(AppModel.self) private var model
    var insets = EdgeInsets()

    var body: some View {
        if case .failed(let message) = model.phase {
            ErrorBanner(message: message)
                .padding(insets)
        }
    }
}

/// Brings a page's first row back on screen when a failure lands, so its banner is seen; once per failure, so it never fights a scroll.
private struct FailureScroll: View {
    @Environment(AppModel.self) private var model
    let proxy: ScrollViewProxy

    var body: some View {
        Color.clear
            .onChange(of: failureMessage) { _, message in
                guard message != nil else { return }
                proxy.scrollTo(LibraryListItem.pageTopID, anchor: .top)
            }
    }

    private var failureMessage: String? {
        if case .failed(let message) = model.phase { return message }
        return nil
    }
}

extension LibraryEmptyAction {
    var title: LocalizedStringKey {
        switch self {
        case .openFile: return "Open Files…"
        case .recordMicrophone: return "Record"
        case .recordSystemAudio: return "Record System Audio"
        case .startDictation: return "Start Dictation"
        case .meetingSettings: return "Set Up Meeting Recording"
        case .dictationSettings: return "Dictation Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .openFile: return "doc.badge.plus"
        case .recordMicrophone: return "mic.fill"
        case .recordSystemAudio: return "waveform.circle.fill"
        case .startDictation: return DS.categorySymbol(for: .dictation)
        case .meetingSettings, .dictationSettings: return "gearshape"
        }
    }

    var axLeaf: String {
        switch self {
        case .openFile: return "OpenFiles"
        case .recordMicrophone: return "Record"
        case .recordSystemAudio: return "RecordSystemAudio"
        case .startDictation: return "StartDictation"
        case .meetingSettings: return "MeetingSettings"
        case .dictationSettings: return "DictationSettings"
        }
    }
}

/// The source key, not a `LocalizedStringKey`, so callers can both show it and interpolate it into a sentence.
func libraryCategoryName(_ category: EntryCategory) -> String {
    switch category {
    case .transcription: return "Transcriptions"
    case .meeting: return "Meetings"
    case .dictation: return "Dictations"
    }
}
