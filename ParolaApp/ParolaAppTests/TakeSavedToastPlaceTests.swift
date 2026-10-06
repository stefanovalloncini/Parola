import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Saved take toast: which take, and where", .serialized)
struct TakeSavedToastPlaceTests {
    private func makeModel() -> AppModel {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("take-saved-place"))
        model.libraryLoaded = true
        return model
    }

    private func italian() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    /// The transcript of `entryID` on screen, as a take that just landed leaves it.
    private func show(_ entryID: LibraryEntry.ID, on model: AppModel) {
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Weekly numbers.")], language: "en", modelName: "stub"
        )
        model.selectedEntryID = entryID
        model.phase = .ready
        model.route = .transcript
    }

    private func entry(_ title: String, category: EntryCategory) -> LibraryEntry {
        var manifest = ParolaDocument.Manifest(originalAudioName: "\(title).m4a", title: title, modelName: "stub", language: "en")
        manifest.category = category
        return LibraryEntry(id: "landed", bundleURL: URL(fileURLWithPath: "/tmp/landed.parola"), manifest: manifest)
    }

    @Test("the toast names the take and the page it went to")
    func namesTheTake() throws {
        #expect(TakeSavedToast.message(title: "Weekly sync", category: .meeting) == "Saved “Weekly sync” to Meetings")
        #expect(TakeSavedToast.message(title: "Notes", category: .transcription) == "Saved “Notes” to Transcriptions")
        #expect(TakeSavedToast.message(title: "Weekly sync", category: .meeting, bundle: try italian()) == "“Weekly sync” salvata in Riunioni")
    }

    @Test("a take or run saved out of sight says it in the same words; a watched file still says where it came from")
    func oneSentenceShape() throws {
        let meeting = entry("Weekly sync", category: .meeting)
        #expect(ArrivalNotice(landed: meeting, origin: .take).title() == "Saved “Weekly sync” to Meetings")
        #expect(ArrivalNotice(landed: meeting, origin: .run).title() == "Saved “Weekly sync” to Meetings")
        #expect(ArrivalNotice(landed: meeting, origin: .watchedFolder).title() == "Transcribed Weekly sync from a watched folder")
        #expect(ArrivalNotice(landed: meeting, origin: .take).title(bundle: try italian()) == "“Weekly sync” salvata in Riunioni")
    }

    @Test("the toast shows under its own take's transcript only")
    func showsOnItsTake() {
        let model = makeModel()
        show("E", on: model)
        model.takeSavedNotice = TakeSavedNotice(entryID: "E", title: "Weekly sync", category: .meeting)
        #expect(model.takeSavedToastIsOnItsTake)

        model.takeSavedNotice = TakeSavedNotice(entryID: "F", title: "Other", category: .meeting)
        #expect(!model.takeSavedToastIsOnItsTake)
    }

    @Test("under another transcript the window draws no Summarize or Copy for the take")
    func notDrawnUnderAnotherTranscript() async {
        let model = makeModel()
        show("E", on: model)
        model.takeSavedNotice = TakeSavedNotice(entryID: "F", title: "Other", category: .meeting)
        let hosted = HostedWindow(ContentView().environment(model), width: MainWindowLayout.minimumWidth, height: MainWindowLayout.minimumHeight)
        defer { hosted.close() }
        func drawsCopy() -> Bool {
            HostedAccessibility.elements(in: hosted.host).contains { $0.identifier?.hasSuffix("TakeSaved.Button.Copy") == true }
        }
        await settle(for: .milliseconds(300))
        #expect(!drawsCopy())

        model.takeSavedNotice = TakeSavedNotice(entryID: "E", title: "Weekly sync", category: .meeting)
        let drawn = await waitUntil { drawsCopy() }
        #expect(drawn)
    }

    @Test("once seen, the toast goes when you open another page or another entry")
    func goesWhenYouLeave() {
        let model = makeModel()
        show("E", on: model)
        model.takeSavedNotice = TakeSavedNotice(entryID: "E", title: "Weekly sync", category: .meeting)
        model.takeSavedCameOnScreen()
        model.route = .statistics
        #expect(model.takeSavedNotice == nil)

        show("E", on: model)
        model.takeSavedNotice = TakeSavedNotice(entryID: "E", title: "Weekly sync", category: .meeting)
        model.takeSavedCameOnScreen()
        model.selectedEntryID = "F"
        #expect(model.takeSavedNotice == nil)
    }

    @Test("a toast seen once, then covered by a new take's Stage, goes when you open another page")
    func seenThenCoveredGoesWhenYouLeave() {
        let model = makeModel()
        show("E", on: model)
        model.takeSavedNotice = TakeSavedNotice(entryID: "E", title: "Weekly sync", category: .meeting)
        model.takeSavedCameOnScreen()
        model.installTestTake(source: .microphone)
        defer { model.endTestTake() }
        #expect(model.noticesWaitForStage)

        model.route = .statistics
        #expect(model.takeSavedNotice == nil)
    }

    @Test("before it has been seen, a landing's own moves don't take it down")
    func landingKeepsIt() {
        let model = makeModel()
        model.takeSavedNotice = TakeSavedNotice(entryID: "E", title: "Weekly sync", category: .meeting)
        model.selectedEntryID = nil
        model.route = .transcript
        model.selectedEntryID = "E"
        #expect(model.takeSavedNotice != nil)
    }
}
