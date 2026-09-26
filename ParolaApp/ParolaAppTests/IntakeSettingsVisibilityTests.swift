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
        model.searchRanking = []
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

@MainActor
@Suite("Intake settings toolbar rule", .serialized)
struct IntakeSettingsToolbarRuleTests {

    private func makeModel() -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults("test-intake-toolbar-"),
            libraryURL: makeTempLibraryURL("intake-toolbar")
        )
    }

    private func shows(
        route: AppModel.Route,
        browsing: Bool = false,
        settingsPreview: Bool = false,
        introduction: Bool = false
    ) -> Bool {
        IntakeSettings.areShown(
            route: route,
            isBrowsingLibrary: browsing,
            settingsPreview: settingsPreview,
            introductionPresented: introduction
        )
    }

    @Test("Home and an open transcript show the pills")
    func transcriptRouteShows() {
        #expect(shows(route: .transcript))
    }

    @Test("the activity and library pages hide the pills")
    func otherRoutesHide() {
        #expect(!shows(route: .queue))
        #expect(!shows(route: .batch))
        #expect(!shows(route: .statistics))
        #expect(!shows(route: .recentlyDeleted))
        #expect(!shows(route: .transcript, browsing: true))
    }

    @Test("the settings preview and the introduction hide the pills")
    func overlaysHide() {
        #expect(!shows(route: .transcript, settingsPreview: true))
        #expect(!shows(route: .transcript, introduction: true))
    }

    @Test("every phase on the transcript route shows the pills")
    func phasesShow() {
        let model = makeModel()
        model.route = .transcript
        let phases: [AppModel.Phase] = [
            .idle,
            .downloadingModel(name: "tiny", progress: 0.4),
            .loadingModel(name: "tiny"),
            .transcribing(file: URL(fileURLWithPath: "/tmp/a.wav")),
            .recording(source: .microphone),
            .exporting(progress: 0.2),
            .ready,
            .failed(message: "boom")
        ]
        for phase in phases {
            model.phase = phase
            #expect(shows(route: model.route, browsing: model.isBrowsingLibrary))
        }
    }

    @Test("a library list hides the pills whatever the phase leaves behind")
    func browsingHides() {
        let model = makeModel()
        model.route = .transcript
        model.phase = .idle
        model.libraryFilter = .meeting
        #expect(model.isBrowsingLibrary)
        #expect(!shows(route: model.route, browsing: model.isBrowsingLibrary))
    }
}
