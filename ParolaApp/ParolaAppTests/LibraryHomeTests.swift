import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Library is home")
struct LibraryHomeTests {
    private func makeModel() -> AppModel {
        AppModel(bootstrap: AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("library-home"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: TestFilePicker(),
            clock: ContinuousClock()
        ))
    }

    @Test("a fresh launch shows the library, not a start page")
    func launchShowsLibrary() {
        let model = makeModel()
        #expect(model.route == .transcript)
        #expect(model.isBrowsingLibrary)
        #expect(model.libraryFilter == nil)
    }

    @Test("goHome from a category lands on every entry")
    func goHomeShowsAll() {
        let model = makeModel()
        model.browseCategory(.meeting)
        model.goHome()
        #expect(model.isBrowsingLibrary)
        #expect(model.libraryFilter == nil)
        #expect(model.personFilter == nil)
    }

    @Test("closing Recently Deleted returns to the library")
    func recentlyDeletedReturns() {
        let model = makeModel()
        model.openRecentlyDeleted()
        model.closeRecentlyDeleted()
        #expect(model.route == .transcript)
        #expect(model.isBrowsingLibrary)
    }

    @Test("a failure keeps the library on screen with its banner")
    func failureKeepsLibrary() {
        let model = makeModel()
        model.phase = .failed(message: "The file couldn't be decoded.")
        #expect(model.isBrowsingLibrary)
    }

    @Test("the bridge reports the whole library only while nothing narrows it")
    func bridgeReportsTheWholeLibrary() throws {
        let model = makeModel()
        let server = try ParolaAutomationServer(model: model)
        func browsingAll() -> AutomationValue? {
            guard case .object(let state) = server.snapshotState() else { return nil }
            return state["libraryBrowsingAll"]
        }

        #expect(browsingAll() == .bool(true))
        model.browseCategory(.meeting)
        #expect(browsingAll() == .bool(false))
        model.goHome()
        model.personFilter = UUID()
        #expect(browsingAll() == .bool(false))
        model.goHome()
        model.searchRanking = []
        #expect(browsingAll() == .bool(false), "results cover the library page")
    }

    @Test("a watched-folder arrival may take the whole library, never a narrowed list")
    func arrivalTakesOnlyTheWholeLibrary() {
        let model = makeModel()
        #expect(model.arrivalMayTakeWindow)
        model.browseCategory(.meeting)
        #expect(!model.arrivalMayTakeWindow)
        model.goHome()
        model.personFilter = UUID()
        #expect(!model.arrivalMayTakeWindow)
        model.goHome()
        model.searchRanking = []
        #expect(!model.arrivalMayTakeWindow)
    }
}
