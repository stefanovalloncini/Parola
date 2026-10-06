import AppKit
import Foundation
import SwiftUI
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

// @unchecked: only written from the observation callback, which the model raises on the main actor.
private final class InvalidationFlag: @unchecked Sendable {
    var fired = false
}

@MainActor
@Suite("Sidebar badge counts")
struct SidebarBadgeCountTests {
    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// AppModel's init kicks off a library refresh; letting it land keeps it from clobbering the seeded entries.
    private func makeModel() async -> AppModel {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("badges")
        )
        await model.libraryRefreshTask?.value
        return model
    }

    private func entry(
        _ id: String, title: String? = nil, category: EntryCategory = .transcription, pinned: Bool = false
    ) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(
            createdAt: Self.baseDate,
            originalAudioName: "\(id).m4a",
            title: title ?? id.uppercased(),
            modelName: "stub",
            language: "en",
            category: category,
            pinned: pinned
        )
        return LibraryEntry(
            id: id,
            bundleURL: URL(fileURLWithPath: "/tmp/SidebarBadgeCountTests/\(id).parola"),
            manifest: manifest
        )
    }

    private func job(_ name: String, status: BatchJob.Status) -> BatchJob {
        BatchJob(url: URL(fileURLWithPath: "/tmp/SidebarBadgeCountTests/\(name).wav"), status: status)
    }

    private func entry(_ id: String, assigning map: [String: UUID]) -> LibraryEntry {
        var built = entry(id)
        var manifest = built.manifest
        manifest.speakerAssignments = map
        built = LibraryEntry(id: built.id, bundleURL: built.bundleURL, manifest: manifest)
        return built
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "|" : $0.title }
    }

    @Test("a person's badge counts the transcripts they are in, not their labels")
    func personBadgeCountsTranscripts() async {
        let model = await makeModel()
        let ada = Person(name: "Ada")
        model.people = [ada]
        model.libraryEntries = [
            entry("a", assigning: ["SPEAKER_00": ada.id, "SPEAKER_01": ada.id]),
            entry("b", assigning: ["SPEAKER_00": ada.id]),
            entry("c"),
        ]

        #expect(model.transcriptCount(of: ada) == 2)
    }

    @Test("past five people the section ends on All People…, which opens the directory")
    func allPeopleRow() async {
        let model = await makeModel()
        model.people = (0..<6).map { Person(name: "Person \($0)") }
        let sidebar = HostedWindow(LibrarySidebar().environment(model), width: 240, height: 760)
        defer { sidebar.close() }
        _ = await waitUntil { sidebar.rowCount > 8 }

        let words = HostedAccessibility.words(in: sidebar.host)
        #expect(words.contains("All People…"), "\(words)")
        let pressed = HostedAccessibility.press(endingWith: "Row.AllPeople", in: sidebar.host)
        #expect(pressed)
        #expect(model.showingPeopleSheet)

        model.showingPeopleSheet = false
        model.people = Array(model.people.prefix(5))
        _ = await waitUntil { !HostedAccessibility.words(in: sidebar.host).contains("All People…") }
        #expect(!HostedAccessibility.words(in: sidebar.host).contains("All People…"), "five fit, so nothing is left out")
    }

    @Test("a person's right-click acts on them, then offers the directory")
    func personMenu() throws {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("person-menu"))
        let ada = Person(name: "Ada")
        model.people = [ada]
        let menu = NSHostingMenu(rootView: PersonRowMenu(model: model, person: ada))
        menu.update()

        #expect(titles(menu) == ["Show Transcripts", "Rename…", "This Is Me", "Delete…", "|", "Manage People…"])

        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == "Rename…" }))
        #expect(model.peopleSheetRequest == .rename(ada.id))
        #expect(model.showingPeopleSheet)

        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == "Delete…" }))
        #expect(model.peopleSheetRequest == .delete(ada.id))

        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == "Show Transcripts" }))
        #expect(model.personFilter == ada.id)
    }

    @Test("a rename the directory never took is dropped when it closes, so Manage People… opens plain")
    func untakenRequestGoesWithTheSheet() {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("person-request"))
        let ada = Person(name: "Ada")
        model.people = [ada]

        model.managePerson(.rename(ada.id))
        model.showingPeopleSheet = false
        model.showingPeopleSheet = true

        #expect(model.peopleSheetRequest == nil)
    }

    @Test("the queue badge follows a status changed in place")
    func queueBadgeFollowsInPlaceStatus() async {
        let model = await makeModel()
        model.batchJobs = [
            job("a", status: .pending),
            job("b", status: .transcribing),
            job("c", status: .done),
        ]
        #expect(model.sidebarActivity == .inProgress(count: 2))

        model.batchJobs[1].status = .done
        #expect(model.sidebarActivity == .inProgress(count: 1))

        model.batchJobs[0].status = .failed
        #expect(model.sidebarActivity == .failed(count: 1))
    }

    @Test("the Activity row stays while a job waits or runs, then while a failure is under a day old")
    func activityFollowsInPlaceStatus() async {
        let model = await makeModel()
        #expect(!model.sidebarShowsActivity)

        model.batchJobs = [job("a", status: .pending), job("b", status: .done)]
        #expect(model.sidebarActivity == .inProgress(count: 1))

        model.batchJobs[0].status = .failed
        #expect(model.sidebarActivity == .failed(count: 1), "the row turns into Failed, counted")
        let failedAt = model.batchFailedAt[model.batchJobs[0].id]
        #expect(failedAt != nil)

        model.refreshSidebarActivity(now: (failedAt ?? Date()).addingTimeInterval(SidebarActivity.failureWindow + 1))
        #expect(!model.sidebarShowsActivity, "a day later the failure lets the row go")

        model.batchJobs[0].status = .pending
        #expect(model.sidebarActivity == .inProgress(count: 1), "a retry is work again")
        #expect(model.batchFailedAt.isEmpty)

        model.batchJobs[0].status = .cancelled
        #expect(!model.sidebarShowsActivity)
    }

    @Test("the Queue row is named Queue while jobs wait")
    func activityRowReadsQueue() async {
        let model = await makeModel()
        model.batchJobs = [job("a", status: .transcribing), job("b", status: .pending)]
        let sidebar = HostedWindow(LibrarySidebar().environment(model), width: 240, height: 600)
        defer { sidebar.close() }
        _ = await waitUntil { sidebar.rowCount > 4 }
        let words = HostedAccessibility.words(in: sidebar.host)
        #expect(words.contains("Queue"), "\(words)")
        #expect(!words.contains("In Progress"), "\(words)")
        #expect(!words.contains("Failed"), "\(words)")
    }

    @Test("the Queue row says Failed once only failures remain")
    func activityRowReadsFailed() async {
        let model = await makeModel()
        model.batchJobs = [job("a", status: .failed), job("b", status: .failed), job("c", status: .done)]
        let sidebar = HostedWindow(LibrarySidebar().environment(model), width: 240, height: 600)
        defer { sidebar.close() }
        _ = await waitUntil { sidebar.rowCount > 4 }
        let words = HostedAccessibility.words(in: sidebar.host)
        #expect(words.contains("Queue"), "\(words)")
        #expect(words.contains("Failed"), "\(words)")
        #expect(!words.contains("In Progress"), "\(words)")
    }

    @Test("a progress tick that leaves the count alone does not invalidate the badge or the Activity row")
    func queueBadgeSkipsUnchangedCount() async {
        let model = await makeModel()
        model.batchJobs = [job("a", status: .transcribing)]
        let invalidated = InvalidationFlag()
        withObservationTracking {
            _ = model.sidebarActivity
            _ = model.sidebarShowsActivity
        } onChange: {
            invalidated.fired = true
        }

        await model.handleBatchEvent(.progress(jobID: model.batchJobs[0].id, fraction: 0.4))
        await model.handleBatchEvent(.progress(jobID: model.batchJobs[0].id, fraction: 0.7))
        model.batchJobs[0].segmentCount = 2
        #expect(!invalidated.fired)

        model.batchJobs[0].status = .done
        #expect(invalidated.fired)
    }

    @Test("the library badges count every entry and each category")
    func libraryBadgesCountTheCategories() async {
        let model = await makeModel()
        model.libraryEntries = [
            entry("a"),
            entry("b", category: .meeting),
            entry("c", category: .meeting),
            entry("d", category: .dictation),
        ]

        #expect(model.libraryCounts.total == 4)
        #expect(model.libraryCounts.count(of: .transcription) == 1)
        #expect(model.libraryCounts.count(of: .meeting) == 2)
        #expect(model.libraryCounts.count(of: .dictation) == 1)
    }

    @Test("a library write that keeps every count leaves the library badges alone")
    func libraryBadgesSkipUnchangedCounts() async {
        let model = await makeModel()
        model.libraryEntries = [entry("a"), entry("b", category: .meeting)]
        let invalidated = InvalidationFlag()
        withObservationTracking {
            _ = model.libraryCounts
        } onChange: {
            invalidated.fired = true
        }

        model.libraryEntries = [entry("a", title: "Renamed"), entry("b", category: .meeting, pinned: true)]
        #expect(!invalidated.fired)

        model.libraryEntries = [entry("a", title: "Renamed")]
        #expect(invalidated.fired)
    }

    @Test("re-listing the same deleted entries leaves the trash badge alone")
    func deletedBadgeSkipsUnchangedList() async {
        let model = await makeModel()
        model.setDeletedEntries([entry("a"), entry("b")])
        let invalidated = InvalidationFlag()
        withObservationTracking {
            _ = model.deletedEntries.count
        } onChange: {
            invalidated.fired = true
        }

        model.setDeletedEntries([entry("a"), entry("b")])
        #expect(!invalidated.fired)

        model.setDeletedEntries([entry("a")])
        #expect(invalidated.fired)
    }

    @Test("a renamed deleted entry still reaches the trash list")
    func deletedListSeesRename() async {
        let model = await makeModel()
        model.setDeletedEntries([entry("a")])

        model.setDeletedEntries([entry("a", title: "Renamed")])

        #expect(model.deletedEntries.first?.title == "Renamed")
    }
}
