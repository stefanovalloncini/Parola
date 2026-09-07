import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Intake settings visibility", .serialized)
struct IntakeSettingsVisibilityTests {

    private func makeModel() -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults("test-intake-visibility-"),
            libraryURL: makeTempLibraryURL("intake-visibility")
        )
    }

    @Test("Home is not a library list")
    func homeIsNotBrowsing() {
        let model = makeModel()
        model.route = .transcript
        model.phase = .idle
        #expect(!model.isBrowsingLibrary)
    }

    @Test("a category, All and a search all count as browsing")
    func libraryListsCountAsBrowsing() {
        let model = makeModel()
        model.route = .transcript
        model.phase = .idle

        model.libraryFilter = .meeting
        #expect(model.isBrowsingLibrary)

        model.libraryFilter = nil
        model.libraryBrowsingAll = true
        #expect(model.isBrowsingLibrary)

        model.libraryBrowsingAll = false
        model.searchResults = []
        #expect(model.isBrowsingLibrary)
    }

    @Test("the queue and batch routes keep the intake settings")
    func activityRoutesAreNotBrowsing() {
        let model = makeModel()
        model.libraryBrowsingAll = true
        model.phase = .idle

        model.route = .queue
        #expect(!model.isBrowsingLibrary)

        model.route = .batch
        #expect(!model.isBrowsingLibrary)
    }

    @Test("a run in flight is never a library list")
    func busyPhasesAreNotBrowsing() {
        let model = makeModel()
        model.route = .transcript
        model.libraryBrowsingAll = true

        model.phase = .transcribing(file: URL(fileURLWithPath: "/tmp/a.wav"))
        #expect(!model.isBrowsingLibrary)

        model.phase = .failed(message: "boom")
        #expect(!model.isBrowsingLibrary)
    }

    @Test("a batch detail pane keeps the intake settings")
    func batchDetailIsNotBrowsing() {
        let model = makeModel()
        model.route = .transcript
        model.phase = .idle
        model.libraryBrowsingAll = true
        model.batchJobs = [BatchJob(url: URL(fileURLWithPath: "/tmp/a.wav"), status: .done)]
        #expect(!model.isBrowsingLibrary)
    }
}
