import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Library browsing", .serialized)
struct LibraryBrowsingTests {

    private func makeModel() -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults("test-library-browsing-"),
            libraryURL: makeTempLibraryURL("library-browsing")
        )
    }

    @Test("the Library page, a category and a search all count as browsing")
    func libraryListsCountAsBrowsing() {
        let model = makeModel()
        model.route = .transcript
        model.phase = .idle
        #expect(model.isBrowsingLibrary)

        model.libraryFilter = .meeting
        #expect(model.isBrowsingLibrary)

        model.libraryFilter = nil
        model.searchRanking = []
        #expect(model.isBrowsingLibrary)
    }

    @Test("the queue and batch routes are not the library list")
    func activityRoutesAreNotBrowsing() {
        let model = makeModel()
        model.phase = .idle

        model.route = .queue
        #expect(!model.isBrowsingLibrary)

        model.route = .batch
        #expect(!model.isBrowsingLibrary)
    }

    @Test("a run in flight is never a library list, and a failure leaves the list up")
    func busyPhasesAreNotBrowsing() {
        let model = makeModel()
        model.route = .transcript

        model.phase = .transcribing(file: URL(fileURLWithPath: "/tmp/a.wav"))
        #expect(!model.isBrowsingLibrary)

        model.phase = .failed(message: "boom")
        #expect(model.isBrowsingLibrary)
    }

    @Test("a batch detail pane is not the library list")
    func batchDetailIsNotBrowsing() {
        let model = makeModel()
        model.route = .transcript
        model.phase = .idle
        model.batchJobs = [BatchJob(url: URL(fileURLWithPath: "/tmp/a.wav"), status: .done)]
        #expect(!model.isBrowsingLibrary)
    }
}
