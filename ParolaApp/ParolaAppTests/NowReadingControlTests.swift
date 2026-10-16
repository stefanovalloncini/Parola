import Foundation
import ParolaCore
import Testing
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Now Reading control")
struct NowReadingControlTests {
    @Test("it shows for every state but idle and no voice, hides during a take, and narrows below the width", arguments: [
        (ReadAloudController.State.idle, false, false, NowReadingLayout.hidden),
        (.noVoice("fa"), false, false, .hidden),
        (.preparing, false, false, .full),
        (.reading, false, false, .full),
        (.reading, false, true, .compact),
        (.waiting(.slow), false, false, .full),
        (.paused(.user), false, false, .full),
        (.paused(.media), false, true, .compact),
        (.reading, true, false, .hidden),
        (.paused(.take), true, true, .hidden),
        (.failed("x"), false, false, .failed),
        (.failed("x"), false, true, .failedCompact),
        (.failed("x"), true, false, .hidden),
    ] as [(ReadAloudController.State, Bool, Bool, NowReadingLayout)])
    func visibility(state: ReadAloudController.State, take: Bool, narrow: Bool, expected: NowReadingLayout) {
        #expect(NowReadingLayout.resolve(state: state, takeActive: take, isNarrow: narrow) == expected)
    }

    @Test("the model follows a reading's life and the window's width")
    func modelLayout() async {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("now-reading"))
        model.transcript = EntryWindowTestSupport.transcript(texts: ["One two three four.", "Five six seven eight."], speakers: [])
        model.phase = .ready
        #expect(model.nowReadingLayout == .hidden)

        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }
        #expect(model.nowReadingLayout == .full)
        model.windowIsNarrowForReading = true
        #expect(model.nowReadingLayout == .compact)

        await model.stopReading()
        #expect(model.nowReadingLayout == .hidden)
    }

    @Test("Open selects the entry and the pane being read")
    func openSelectsEntry() async throws {
        let model = EntryWindowTestSupport.makeModel("now-reading-open")
        let first = try await EntryWindowTestSupport.seed(model, texts: ["One two three four."], speakers: [nil], audio: nil)
        let second = try await EntryWindowTestSupport.seed(model, texts: ["Five six seven eight."], speakers: [nil], audio: nil)
        model.loadEntry(first.id)
        await waitUntil { model.selectedEntryID == first.id && model.hasTranscript }
        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }

        model.loadEntry(second.id)
        await waitUntil { model.selectedEntryID == second.id && model.hasTranscript }
        await model.openReading()

        #expect(model.selectedEntryID == first.id)
        #expect(model.transcriptPaneMode == .transcript)
        await model.stopReading()
    }

    @Test("the speed label drops trailing zeros")
    func speedLabels() {
        let english = Locale(identifier: "en_US")
        #expect(NowReadingControl.speedLabel(1, locale: english) == "1×")
        #expect(NowReadingControl.speedLabel(0.75, locale: english) == "0.75×")
        #expect(NowReadingControl.speedLabel(1.5, locale: Locale(identifier: "it_IT")) == "1,5×")
    }

    @Test("the control's strings read in English and Italian")
    func localized() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        let keys: [(String, String)] = [
            ("Pause Reading", "Metti in pausa la lettura"),
            ("Resume Reading", "Riprendi la lettura"),
            ("Previous Sentence", "Frase precedente"),
            ("Skip Sentence", "Salta la frase"),
            ("Stop Reading", "Ferma la lettura"),
            ("Now Reading", "In lettura"),
            ("Now Reading: %@ · %@", "In lettura: %1$@ · %2$@"),
            ("Sentence %lld of %lld", "Frase %1$lld di %2$lld"),
            ("Use Built-in Voice", "Usa la voce integrata"),
            ("Try Again", "Riprova"),
        ]
        for (key, expected) in keys {
            #expect(italian.localizedString(forKey: key, value: "MISSING", table: nil) == expected, "Italian for \(key)")
        }
        #expect(String(localized: "Sentence \(2) of \(5)") == "Sentence 2 of 5")
    }

    @Test("getState says whether the control shows and whether the activity is held")
    func bridgeFields() async throws {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("now-reading-state"))
        model.transcript = EntryWindowTestSupport.transcript(texts: ["One two three four.", "Five six seven eight."], speakers: [])
        model.phase = .ready
        func fields() -> [String: AutomationValue] {
            guard case .object(let fields) = ParolaAutomationServer.readAloudState(model) else { return [:] }
            return fields
        }
        #expect(fields()["controlVisible"] == .bool(false))
        #expect(fields()["activityHeld"] == .bool(false))

        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }
        #expect(fields()["controlVisible"] == .bool(true))
        #expect(fields()["activityHeld"] == .bool(true))

        await model.pauseReading()
        #expect(fields()["controlVisible"] == .bool(true))
        #expect(fields()["activityHeld"] == .bool(false))
        await model.stopReading()
    }
}
