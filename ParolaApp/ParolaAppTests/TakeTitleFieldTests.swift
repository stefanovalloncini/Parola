import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

// Closures inside #expect/#require arguments can share a symbol with a later closure in the same test (Swift 6.4); bind waits first.
extension TranscriberMockSuites {
    @MainActor
    @Suite("Take title field", .serialized)
    struct TakeTitleFieldTests {
        @Test("typing names the take the field was typed for, and an empty field gives back the generated name")
        func typingRenamesItsTake() throws {
            let model = makeRecordingModel("title-typing")
            model.installTestTake(source: .microphone)
            let takeID = try #require(model.recording?.takeID)
            let generated = model.recording?.title

            TakeTitleField.commit("Design review", to: takeID, model: model)
            #expect(model.recording?.title == "Design review")
            #expect(model.recording?.titleSource == .user)

            TakeTitleField.commit("Old take", to: takeID - 1, model: model)
            #expect(model.recording?.title == "Design review")

            TakeTitleField.commit("", to: takeID, model: model)
            #expect(model.recording?.title == generated)
            #expect(model.recording?.titleSource == nil)
            model.endTestTake()
        }

        @Test("Meeting files the take as a meeting and its generated name follows; a stale choice changes nothing")
        func categoryFollows() throws {
            let model = makeRecordingModel("title-category")
            model.installTestTake(source: .microphone)
            let takeID = try #require(model.recording?.takeID)

            TakeCategoryPicker.choose(.meeting, for: takeID - 1, model: model)
            #expect(model.recording?.category == .transcription)

            TakeCategoryPicker.choose(.meeting, for: takeID, model: model)
            #expect(model.recording?.category == .meeting)
            #expect(model.recording?.title.hasPrefix("Meeting") == true)
            model.endTestTake()
        }

        @Test("the picker names the categories as the sidebar does, in Italian too")
        func pickerNamesMatchTheSidebar() throws {
            let titles = TakeCategoryPicker.choices.map { TakeCategoryPicker.title(for: $0) }
            #expect(titles == ["Transcription", "Meeting"])
            #expect(TakeSavedToast.message(category: .transcription) == "Saved to Transcriptions")
            let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
            let it = try #require(Bundle(path: path))
            #expect(TakeCategoryPicker.title(for: .transcription, bundle: it) == "Trascrizione")
        }

        @Test("after Stop the name is what the take is saved with")
        func stoppedTakeKeepsItsName() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let model = makeRecordingModel("title-after-stop")
                await installMockTranscriber(segments: [(0, 0.3, "kept")])
                try await startFixtureTake(model)
                let takeID = try #require(model.recording?.takeID)
                TakeTitleField.commit("Kickoff", to: takeID, model: model)
                model.stopRecordingAndTranscribe()
                let stopped = try #require(model.recording)
                #expect(!TakeTitleBar.isEditable(stopped))

                TakeTitleField.commit("Too late", to: takeID, model: model)
                let entry = await landedEntry(model)
                #expect(entry?.title == "Kickoff")
            }
        }

        @Test("the toolbar names the take only while its Stage shows it, from Record until the capture winds down")
        func showsOnTheStage() {
            let model = makeRecordingModel("title-shows")
            #expect(TakeTitleBar.take(on: model) == nil)
            model.installTestTake(source: .microphone)
            #expect(TakeTitleBar.take(on: model)?.takeID == model.recording?.takeID)
            model.goHome()
            #expect(model.route != .recording)
            #expect(TakeTitleBar.take(on: model) == nil)
            model.endTestTake()
        }
    }
}
