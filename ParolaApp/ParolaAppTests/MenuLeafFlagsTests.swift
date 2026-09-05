import Foundation
import ParolaCore
import Testing
@testable import Parola

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
