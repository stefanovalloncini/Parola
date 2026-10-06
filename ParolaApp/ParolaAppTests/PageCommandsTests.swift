import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Menus follow the page in front")
struct PageCommandsTests {
    let model: AppModel

    init() {
        model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("pagecommands"))
    }

    private func openTranscript() {
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello world.")],
            language: "en",
            modelName: "tiny"
        )
        model.phase = .ready
        model.route = .transcript
    }

    @Test("⌘F puts the caret in the library's search field when no transcript is in front")
    func findSearchesTheLibrary() {
        let before = model.librarySearchFocusRequests

        #expect(model.findCommandEnabled)
        model.beginFind()

        #expect(model.librarySearchFocusRequests == before &+ 1)
        #expect(!model.findIsOpen)
    }

    @Test("⌘F searches the Queue while a transcript waits behind it, and is off where no page searches")
    func findFollowsTheRoute() {
        openTranscript()
        model.openQueue()
        let before = model.librarySearchFocusRequests

        #expect(model.findCommandEnabled)
        model.beginFind()
        #expect(model.librarySearchFocusRequests == before &+ 1)
        #expect(!model.findIsOpen)

        model.route = .statistics
        #expect(!model.findCommandEnabled)
    }

    @Test("⌘F finds in the transcript on screen, and in the results laid over it searches instead")
    func findInTheTranscriptOnlyWhenItShows() {
        openTranscript()
        let before = model.librarySearchFocusRequests

        model.beginFind()
        #expect(model.findIsOpen)
        #expect(model.librarySearchFocusRequests == before)

        model.toggleFind()
        model.searchRanking = []
        model.beginFind()
        #expect(!model.findIsOpen)
        #expect(model.librarySearchFocusRequests == before &+ 1)
    }
}
