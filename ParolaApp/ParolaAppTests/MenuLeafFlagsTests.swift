import Foundation
import ParolaCore
import Testing
@testable import Parola
import ParolaTestSupport

// @unchecked: only written from the observation callback, which the model raises on the main actor.
private final class MenuInvalidation: @unchecked Sendable {
    var fired = false
}

@MainActor
@Suite("Menu leaf flags track the state they mirror")
struct MenuLeafFlagsTests {
    private func makeModel(_ label: String) -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL(label)
        )
    }

    private func makeTranscript() -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello world.")],
            language: "en",
            modelName: "tiny"
        )
    }

    @Test("hasTranscript follows the transcript in both directions")
    func hasTranscriptFollowsTranscript() {
        let model = makeModel("leaf-transcript")
        #expect(model.hasTranscript == false)

        model.transcript = makeTranscript()
        #expect(model.hasTranscript)

        model.transcript = nil
        #expect(model.hasTranscript == false)
    }

    @Test("hasMatches follows the find pipeline and clears when find closes")
    func hasMatchesFollowsFind() throws {
        let model = makeModel("leaf-matches")
        model.transcript = makeTranscript()
        #expect(model.hasMatches == false)

        model.findIsOpen = true
        model.findQuery = "Hello"
        model.recomputeMatches()
        try #require(model.matches.isEmpty == false)
        #expect(model.hasMatches)

        model.toggleFind()
        #expect(model.matches.isEmpty)
        #expect(model.hasMatches == false)
    }

    /// Everything the menu bar, the content route, the toolbar and the transcript header decide from.
    private func readMenusAndRoute(_ model: AppModel) {
        _ = HelpCommands(model: model, showShortcuts: {}).body
        _ = FileCommands(model: model).body
        _ = ViewCommands(model: model).body
        _ = EditCommands(model: model).body
        _ = PlaybackCommands(model: model).body
        _ = CaptionsCommands(model: model, scratchpad: ScratchpadController(), liveCaptions: LiveCaptionsController()).body
        _ = TranscriptCommands(model: model).body
        _ = ContentRoutes.routeID(for: model)
        _ = model.isBrowsingLibrary
        _ = model.canReturnToOrigin
        _ = model.batchIsRunning
    }

    private func entry(_ id: String, title: String, favorites: [Int] = []) -> LibraryEntry {
        var manifest = ParolaDocument.Manifest(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            originalAudioName: "\(id).m4a",
            title: title,
            modelName: "stub",
            language: "en"
        )
        manifest.favoriteSegments = favorites
        return LibraryEntry(
            id: id,
            bundleURL: URL(fileURLWithPath: "/tmp/MenuLeafFlagsTests/\(id).parola"),
            manifest: manifest
        )
    }

    @Test("a batch tick or a write that keeps every status reaches neither the menus nor the route; a status change does")
    func batchProgressSkipsMenusAndRoute() async {
        let model = makeModel("leaf-batch-tick")
        await model.libraryRefreshTask?.value
        model.transcript = makeTranscript()
        let job = BatchJob(url: URL(fileURLWithPath: "/tmp/leaf-batch-tick.wav"), status: .transcribing)
        model.batchJobs = [job]
        let invalidated = MenuInvalidation()
        withObservationTracking {
            readMenusAndRoute(model)
        } onChange: {
            invalidated.fired = true
        }

        await model.handleBatchEvent(.progress(jobID: job.id, fraction: 0.4))
        await model.handleBatchEvent(.progress(jobID: job.id, fraction: 0.7))
        // A write to the list that leaves every status alone, as an entry landing makes.
        model.batchJobs[0].entryID = "landed"
        model.batchJobs[0].segmentCount = 3
        #expect(!invalidated.fired)

        await model.handleBatchEvent(.failed(jobID: job.id, reason: "boom"))
        #expect(invalidated.fired)
    }

    @Test("a segment edit, a library write and a new set of hits leave the menus and the route alone")
    func contentChangesSkipMenusAndRoute() async {
        let model = makeModel("leaf-content")
        await model.libraryRefreshTask?.value
        model.transcript = makeTranscript()
        model.libraryEntries = [entry("a", title: "First")]
        model.selectedEntryID = "a"
        model.searchRanking = ["a"]
        let invalidated = MenuInvalidation()
        withObservationTracking {
            readMenusAndRoute(model)
        } onChange: {
            invalidated.fired = true
        }

        var edited = makeTranscript()
        edited.segments[0].text = "Hello there."
        model.transcript = edited
        model.libraryEntries = [entry("a", title: "Renamed")]
        model.searchRanking = []
        #expect(!invalidated.fired)

        model.libraryEntries = [entry("a", title: "Renamed", favorites: [0])]
        #expect(invalidated.fired)
        #expect(model.selectedEntryHasFavorites)
    }

    @Test("recentFiles rereads after recentFilesRaw changes under it")
    func recentFilesCacheInvalidates() {
        let model = makeModel("leaf-recent")
        model.recentFiles = [URL(fileURLWithPath: "/tmp/a.mp3")]
        #expect(model.recentFiles.map(\.lastPathComponent) == ["a.mp3"])

        var list = RecentFilesList(capacity: 10)
        list.note(URL(fileURLWithPath: "/tmp/b.mp3"))
        model.recentFilesRaw = list.encoded

        #expect(model.recentFiles.map(\.lastPathComponent) == ["b.mp3"])
    }
}

@MainActor
@Suite("Live captions menu flags track state")
struct LiveCaptionsLeafFlagsTests {
    @Test("isActive mirrors state.isActive across a stop")
    func isActiveFollowsStop() async {
        let controller = LiveCaptionsController()
        #expect(controller.isActive == false)

        controller.state.isActive = true
        #expect(controller.isActive)

        await controller.stop()
        #expect(controller.isActive == false)
    }

    @Test("a failed event drops isActive and keeps what was captioned")
    func failedEventDropsIsActive() {
        let controller = LiveCaptionsController()
        controller.state.isActive = true
        controller.state.apply(.confirmed(TranscriptSegment(id: 0, start: 0, end: 1, text: "one two")))
        #expect(controller.hasHistory)

        controller.state.apply(.failed("engine died"))

        #expect(controller.isActive == false)
        #expect(controller.hasHistory)
    }

    @Test("hasHistory follows a partial and clears on reset")
    func hasHistoryFollowsPartial() {
        let controller = LiveCaptionsController()
        #expect(controller.hasHistory == false)

        controller.state.apply(.partial(text: "hel"))
        #expect(controller.hasHistory)

        controller.state.reset()
        #expect(controller.hasHistory == false)
    }
}
