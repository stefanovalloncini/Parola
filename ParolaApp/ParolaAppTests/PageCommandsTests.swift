import AppKit
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

    @Test("⌘P, ⌘E, ⌘1–3 and ⇧⌘I wait for a transcript on screen: not on the Queue or results over it")
    func transcriptCommandsNeedTheTranscriptInFront() {
        openTranscript()
        #expect(model.mainTranscriptCommandsEnabled)
        #expect(model.canShow(.transcript))

        model.openQueue()
        #expect(model.hasTranscript, "the Queue keeps the transcript loaded behind it")
        #expect(!model.mainTranscriptCommandsEnabled)
        #expect(!model.canShow(.transcript))

        model.route = .transcript
        model.searchRanking = []
        #expect(!model.mainTranscriptCommandsEnabled)
        #expect(!model.canShow(.transcript))

        model.searchRanking = nil
        #expect(model.mainTranscriptCommandsEnabled)
    }

    @Test("a mode set while another page is in front still lands for when the transcript comes back")
    func paneModeSetsBehindAnotherPage() {
        openTranscript()
        model.transcriptPaneMode = .summary
        model.openQueue()

        model.setTranscriptPaneMode(.transcript)

        #expect(model.transcriptPaneMode == .transcript)
    }

    private func viewMenu() async -> NSMenu? {
        await waitUntil { NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu != nil }
        return NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu
    }

    @Test("View ▸ Go reaches every sidebar page and Statistics on ⌥⌘1–7, and View shows or hides the sidebar")
    func goSectionInTheViewMenu() async throws {
        let view = try #require(await viewMenu())
        let titles = view.items.map(\.title)
        let go = try #require(titles.firstIndex(of: "Go"))
        let pages = ["Library", "Transcriptions", "Meetings", "Dictations", "Activity", "Recently Deleted", "Statistics"]

        for (offset, page) in pages.enumerated() {
            let item = view.items[go + 1 + offset]
            #expect(item.title == page)
            #expect(item.keyEquivalent == String(offset + 1))
            #expect(item.keyEquivalentModifierMask == [.command, .option])
        }
        let sidebar = titles.contains("Show Sidebar") || titles.contains("Hide Sidebar")
        #expect(sidebar)
    }
}
