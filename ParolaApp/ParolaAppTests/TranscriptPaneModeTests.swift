import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Transcript pane mode")
struct TranscriptPaneModeTests {
    private func makeModel(features: Set<ParolaFeature>? = nil) -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("pane-mode"), features: features)
    }

    private func makeTranscript() -> Transcript {
        Transcript(segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hello")], language: "en", modelName: "stub")
    }

    @Test("no mode — including .transcript — is showable without a transcript")
    func noModeShowableWithoutTranscript() {
        let model = makeModel()
        #expect(model.transcript == nil)
        #expect(model.canShow(.transcript) == false)
        #expect(model.canShow(.summary) == false)
        #expect(model.canShow(.chat) == false)

        model.transcript = makeTranscript()
        #expect(model.canShow(.transcript))

        model.transcript = nil
        #expect(model.canShow(.transcript) == false)
    }

    @Test("canShow(.summary/.chat) needs a transcript and the AI feature")
    func summaryChatNeedTranscriptAndAI() {
        let model = makeModel()
        #expect(model.canShow(.summary) == false)
        #expect(model.canShow(.chat) == false)

        model.transcript = makeTranscript()
        #expect(model.canShow(.summary))
        #expect(model.canShow(.chat))
    }

    @Test("canShow(.summary/.chat) is false when the AI feature is off, even with a transcript")
    func summaryChatNeedAIFeature() {
        let model = makeModel(features: Set(ParolaFeature.allCases).subtracting([.ai]))
        model.transcript = makeTranscript()
        #expect(model.canShow(.summary) == false)
        #expect(model.canShow(.chat) == false)
        #expect(model.canShow(.transcript))
    }

    @Test("setTranscriptPaneMode switches when allowed and no-ops otherwise")
    func setTranscriptPaneModeGuards() {
        let model = makeModel()
        model.setTranscriptPaneMode(.summary)
        #expect(model.transcriptPaneMode == .transcript, "no transcript yet, so the switch is refused")

        model.transcript = makeTranscript()
        model.setTranscriptPaneMode(.summary)
        #expect(model.transcriptPaneMode == .summary)

        model.setTranscriptPaneMode(.chat)
        #expect(model.transcriptPaneMode == .chat)

        model.setTranscriptPaneMode(.transcript)
        #expect(model.transcriptPaneMode == .transcript)
    }

    @Test("setTranscriptPaneMode is the same entry point the bridge, the picker and the commands share")
    func setTranscriptPaneModeIsSingleEntryPoint() {
        let model = makeModel(features: Set(ParolaFeature.allCases).subtracting([.ai]))
        model.transcript = makeTranscript()
        model.setTranscriptPaneMode(.chat)
        #expect(model.transcriptPaneMode == .transcript, "AI is off, so chat is refused the same way for every caller")
    }
}
