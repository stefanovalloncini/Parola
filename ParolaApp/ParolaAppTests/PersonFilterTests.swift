import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("The Person filter and the sidebar section")
struct PersonFilterTests {

    private let ada = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let grace = UUID(uuidString: "66666666-7777-8888-9999-000000000000")!

    private func entry(
        id: String,
        offset: TimeInterval,
        assignments: [String: UUID],
        category: EntryCategory = .transcription
    ) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            originalAudioName: "\(id).m4a",
            modelName: "stub",
            language: "en",
            category: category,
            speakerAssignments: assignments
        )
        return LibraryEntry(
            id: id,
            bundleURL: URL(fileURLWithPath: "/tmp/PersonFilterTests/\(id).parola"),
            manifest: manifest
        )
    }

    private func makeModel() async -> AppModel {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("personfilter")
        )
        await model.libraryRefreshTask?.value
        model.libraryEntries = [
            entry(id: "a", offset: 100, assignments: ["Ada": ada]),
            entry(id: "b", offset: 200, assignments: ["Ada": ada, "Grace": grace]),
            entry(id: "c", offset: 300, assignments: [:]),
        ]
        return model
    }

    @Test("entries(withPerson:) picks the entries whose map names that person")
    func entriesWithPerson() async {
        let model = await makeModel()

        #expect(model.entries(withPerson: ada).map(\.id) == ["a", "b"])
        #expect(model.entries(withPerson: grace).map(\.id) == ["b"])
        #expect(model.entries(withPerson: UUID()).isEmpty)
    }

    @Test("the rows keep only the entries assigned to the filtered person")
    func rowsHonourTheFilter() async {
        let model = await makeModel()

        let filtered = LibraryListContent.rows(
            from: model.libraryEntries, category: nil, labelFilter: nil, languageFilter: nil,
            dateRange: .all, personFilter: grace
        )
        #expect(filtered.map(\.id) == ["b"])

        let unfiltered = LibraryListContent.rows(
            from: model.libraryEntries, category: nil, labelFilter: nil, languageFilter: nil,
            dateRange: .all, personFilter: nil
        )
        #expect(unfiltered.count == 3)
    }

    @Test("a person filter counts as an active filter and is dropped where nothing matches")
    func filterSurvival() async {
        let model = await makeModel()
        let active = LibraryListContent.ActiveFilters(person: grace)
        #expect(!active.isEmpty)

        let kept = LibraryListContent.filters(active, survivingIn: nil, entries: model.libraryEntries)
        #expect(kept.person == grace)

        let stale = LibraryListContent.filters(
            LibraryListContent.ActiveFilters(person: UUID()),
            survivingIn: nil,
            entries: model.libraryEntries
        )
        #expect(stale.person == nil)
    }

    @Test("a filter that hides every row reads as the filters' doing")
    func filtersHideEverything() async {
        let model = await makeModel()
        let onlyGrace = LibraryListContent.ActiveFilters(person: grace)
        #expect(!LibraryListContent.filtersHideEverything(onlyGrace, category: .meeting, entries: model.libraryEntries))
        #expect(LibraryListContent.filtersHideEverything(
            LibraryListContent.ActiveFilters(label: "nope", person: grace),
            category: nil,
            entries: model.libraryEntries
        ))
    }

    @Test("browsing to a person brings the library list forward, and clearing it leaves the list alone")
    func settingTheFilterOpensTheList() async {
        let model = await makeModel()
        model.route = .transcript

        model.browsePerson(ada)
        #expect(model.personFilter == ada)
        #expect(model.isBrowsingLibrary)

        model.browsePerson(nil)
        #expect(model.personFilter == nil)
        #expect(model.isBrowsingLibrary)
    }

    @Test("browsing to a person while on a category switches to the whole library, not an intersection")
    func personSelectionClearsTheCategory() async {
        let model = await makeModel()
        model.browseCategory(.transcription)
        #expect(model.libraryFilter == .transcription)

        model.browsePerson(ada)

        #expect(model.personFilter == ada)
        #expect(model.libraryFilter == nil)
        #expect(model.isBrowsingLibrary)
    }

    @Test("re-picking a person the chip narrowed to a category clears back to the whole library")
    func repickingANarrowedPersonClearsTheCategory() async {
        let model = await makeModel()
        model.browsePerson(ada)
        model.libraryFilter = .meeting
        #expect(model.personFilter == ada)

        model.browsePerson(ada)

        #expect(model.personFilter == ada)
        #expect(model.libraryFilter == nil)
        #expect(model.isBrowsingLibrary)
    }

    @Test("re-picking a person still navigates when another route took over, like a batch")
    func repickingAPersonNavigatesFromAnotherRoute() async {
        let model = await makeModel()
        model.browsePerson(ada)
        // Simulates addToQueue / startBatch / a duplicate-import sheet setting route directly.
        model.route = .batch
        #expect(model.personFilter == ada)

        model.browsePerson(ada)

        #expect(model.route == .transcript)
        #expect(model.personFilter == ada)
        #expect(model.isBrowsingLibrary)
    }

    @Test("choosing a category clears the person filter")
    func categorySelectionClearsThePerson() async {
        let model = await makeModel()
        model.browsePerson(ada)
        #expect(model.personFilter == ada)

        model.browseCategory(.meeting)

        #expect(model.personFilter == nil)
        #expect(model.libraryFilter == .meeting)
    }

    @Test("a person filter is the only sidebar row selected when no category is set")
    func personFilterIsTheOnlySidebarSelection() async {
        let model = await makeModel()
        model.libraryFilter = nil
        model.personFilter = grace

        let selected = SidebarRoute.selected(
            route: model.route, searching: model.hasSearchResults,
            filter: model.libraryFilter, person: model.personFilter
        )

        #expect(selected == .person(grace))
        #expect(selected != .library)
    }

    @Test("a person narrowing a category leaves the category row lit, not the person's")
    func chipNarrowingKeepsTheCategoryLit() async {
        let model = await makeModel()
        model.libraryFilter = .meeting
        model.personFilter = grace

        let selected = SidebarRoute.selected(
            route: model.route, searching: model.hasSearchResults,
            filter: model.libraryFilter, person: model.personFilter
        )

        #expect(selected == .category(.meeting))
        #expect(selected != .person(grace))
    }

    @Test("a person filter never lights the sidebar row while on another route, like a batch")
    func personFilterIgnoredOffTheLibraryRoute() async {
        let model = await makeModel()
        model.route = .batch
        model.personFilter = grace

        let selected = SidebarRoute.selected(
            route: model.route, searching: model.hasSearchResults,
            filter: model.libraryFilter, person: model.personFilter
        )

        #expect(selected == .batch)
        #expect(selected != .person(grace))
    }

    @Test("the list's page title names the selected person only when no category is set")
    func headerTitleNamesThePerson() {
        let person = Person(name: "Ada Lovelace")
        #expect(LibraryListContent.headerTitle(for: .meeting, person: person) == "Meetings")
        #expect(LibraryListContent.headerTitle(for: nil, person: person) == "Ada Lovelace")
        #expect(LibraryListContent.headerTitle(for: .meeting, person: nil) == "Meetings")
        #expect(LibraryListContent.headerTitle(for: nil, person: nil) == "Library")
    }

    @Test("the person chip stays up when the filter is active, even with no options to switch to")
    func personChipSurvivesAnEmptyCategory() {
        #expect(!LibraryFilterBar.showsPersonFilter(peopleOptions: [], personFilter: nil))
        #expect(LibraryFilterBar.showsPersonFilter(peopleOptions: [], personFilter: grace))
        #expect(LibraryFilterBar.showsPersonFilter(peopleOptions: [Person(name: "Ada")], personFilter: nil))
    }

    @Test("Clear Filters resets every dimension, including the person")
    func clearFiltersResetsThePersonToo() {
        var label: String? = "work"
        var language: String? = "it"
        var dateRange: LibraryDateRangeFilter = .week
        var person: UUID? = ada

        LibraryListContent.clearFilters(
            labelFilter: &label, languageFilter: &language, dateRangeFilter: &dateRange, personFilter: &person
        )

        #expect(label == nil)
        #expect(language == nil)
        #expect(dateRange == .all)
        #expect(person == nil)
    }

    @Test("the filter offers only people with an entry in the category on screen")
    func knownPeopleAreScoped() async {
        let model = await makeModel()
        let adaPerson = Person(id: ada, name: "Ada")
        let gracePerson = Person(id: grace, name: "Grace")
        let stranger = Person(name: "Nobody here")
        model.people = [adaPerson, gracePerson, stranger]
        model.libraryEntries = [
            entry(id: "a", offset: 100, assignments: ["Ada": ada]),
            entry(id: "b", offset: 200, assignments: ["Grace": grace], category: .meeting),
        ]

        #expect(Set(model.knownPeople(in: nil).map(\.id)) == [ada, grace])
        #expect(model.knownPeople(in: .transcription).map(\.id) == [ada])
        #expect(model.knownPeople(in: .meeting).map(\.id) == [grace])
        #expect(!model.knownPeople(in: nil).contains { $0.id == stranger.id })
    }

    @Test("the sidebar section hides when it is switched off or the directory is empty")
    func sidebarVisibility() {
        let person = Person(name: "Ada")
        #expect(PeopleSidebarSection.isVisible(showMostUsed: true, people: [person]))
        #expect(!PeopleSidebarSection.isVisible(showMostUsed: false, people: [person]))
        #expect(!PeopleSidebarSection.isVisible(showMostUsed: true, people: []))
    }

    @Test("the sidebar lists the five most assigned people, most used first")
    func sidebarOrder() async {
        let model = await makeModel()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let uses: [(person: Person, labels: Int)] = [
            (Person(name: "One", lastUsedAt: base), 1),
            (Person(name: "Six", lastUsedAt: base.addingTimeInterval(60)), 1),
            (Person(name: "Nine", lastUsedAt: base), 9),
            (Person(name: "Five", lastUsedAt: base), 5),
            (Person(name: "Seven", lastUsedAt: base), 7),
            (Person(name: "Three", lastUsedAt: base), 3),
        ]
        model.people = uses.map(\.person)
        model.libraryEntries = uses.map { use in
            let labels = (0..<use.labels).map { ("\(use.person.name) \($0)", use.person.id) }
            return entry(id: use.person.name, offset: 0, assignments: Dictionary(uniqueKeysWithValues: labels))
        }

        let rows = model.mostUsedPeople(limit: PeopleSidebarSection.rowLimit)
        #expect(rows.map(\.name) == ["Nine", "Seven", "Five", "Three", "Six"])
    }

    @Test("the sidebar toggle is a bridge-writable setting that survives a reload")
    func toggleIsPersisted() {
        let defaults = temporaryDefaults()
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("peopletoggle"))
        #expect(model.showMostUsedPeople)

        model.showMostUsedPeople = false
        #expect(defaults.bool(forKey: "showMostUsedPeople") == false)

        defaults.set(true, forKey: "showMostUsedPeople")
        model.reloadSettings()
        #expect(model.showMostUsedPeople)

        #expect(ParolaAutomationServer.writableSettingKeys.contains("showMostUsedPeople"))
        #expect(SettingsPaneScope.people.defaultsKeys.contains("showMostUsedPeople"))
    }

    @Test("the People pane sits in the transcription group, after Translation")
    func paneIsInTheSidebar() throws {
        let group = try #require(
            SettingsSidebarCatalog.all.first { $0.id == "transcription" }
        )
        let routes = group.routes
        #expect(routes.contains(.people))
        if let translation = routes.firstIndex(of: .translation), let people = routes.firstIndex(of: .people) {
            #expect(people == translation + 1)
        }
        #expect(SettingsRoute.people.isVisible(features: .all))
        #expect(SettingsSidebarCatalog.matches(route: .people, query: "speaker"))
    }
}
