import Foundation
import ParolaCore
import Testing
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Now Reading control")
struct NowReadingControlTests {
    @Test("it shows for every state but idle and no voice, hides during a take, and shrinks with the window", arguments: [
        (ReadAloudController.State.idle, false, NowReadingWidth.wide, NowReadingLayout.hidden),
        (.noVoice("fa"), false, .wide, .hidden),
        (.preparing, false, .wide, .full),
        (.reading, false, .wide, .full),
        (.reading, false, .medium, .compact),
        (.reading, false, .narrow, .minimal),
        (.waiting(.slow), false, .wide, .full),
        (.paused(.user), false, .wide, .full),
        (.paused(.media), false, .medium, .compact),
        (.paused(.user), false, .narrow, .minimal),
        (.reading, true, .wide, .hidden),
        (.paused(.take), true, .narrow, .hidden),
        (.failed("x"), false, .wide, .failed),
        (.failed("x"), false, .medium, .failed),
        (.failed("x"), false, .narrow, .failed),
        (.failed("x"), true, .wide, .hidden),
    ] as [(ReadAloudController.State, Bool, NowReadingWidth, NowReadingLayout)])
    func visibility(state: ReadAloudController.State, take: Bool, width: NowReadingWidth, expected: NowReadingLayout) {
        #expect(NowReadingLayout.resolve(state: state, takeActive: take, width: width) == expected)
    }

    @Test("the width tier changes at the measured widths", arguments: [
        (900.0, NowReadingWidth.narrow), (1199.0, .narrow), (1200.0, .medium), (1599.0, .medium), (1600.0, .wide), (1800.0, .wide),
    ] as [(Double, NowReadingWidth)])
    func tiers(width: Double, expected: NowReadingWidth) {
        #expect(NowReadingWidth.tier(for: width) == expected)
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
        model.windowWidthTierForReading = .medium
        #expect(model.nowReadingLayout == .compact)
        model.windowWidthTierForReading = .narrow
        #expect(model.nowReadingLayout == .hidden)

        await model.stopReading()
        #expect(model.nowReadingLayout == .hidden)
    }

    @Test("on a narrow window with the transcript toolbar up, the read button's menu carries the controls and no item is added")
    func narrowTranscriptWindowUsesTheReadButton() async throws {
        let model = EntryWindowTestSupport.makeModel("now-reading-narrow")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["One two three four.", "Five six seven eight."], speakers: [nil, nil], audio: nil
        )
        model.loadEntry(entry.id)
        await waitUntil { model.hasTranscript && model.transcriptToolbarShows }
        model.readAloud.mockVoice?.install(msPerUnit: 60_000, failAtUnit: nil)
        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }

        model.windowWidthTierForReading = .wide
        #expect(model.nowReadingLayout == .full)
        #expect(!model.readButtonCarriesTransport)
        model.windowWidthTierForReading = .medium
        #expect(model.nowReadingLayout == .compact)
        #expect(!model.readButtonCarriesTransport)
        model.windowWidthTierForReading = .narrow
        #expect(model.nowReadingLayout == .hidden)
        #expect(model.readButtonCarriesTransport)
        await model.stopReading()
        #expect(!model.readButtonCarriesTransport)
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

    @Test("Open from a Summary reading selects the Summary pane; from a Transcript reading while on Chat it selects Transcript")
    func openSelectsPane() async throws {
        let model = EntryWindowTestSupport.makeModel("now-reading-pane")
        let entry = try await EntryWindowTestSupport.seed(model, texts: ["One two three four."], speakers: [nil], audio: nil)
        model.loadEntry(entry.id)
        await waitUntil { model.selectedEntryID == entry.id && model.hasTranscript }
        model.transcript?.summary = Summary(text: "The team agreed on the plan.", actionItems: ["Send the notes"])
        model.readAloud.mockVoice?.install(msPerUnit: 60_000, failAtUnit: nil)

        await model.readAloud(ReadAloudRequest(kind: .summary))
        await waitUntil { model.readAloud.state == .reading }
        model.setTranscriptPaneMode(.transcript)
        await model.openReading()
        #expect(model.transcriptPaneMode == .summary)

        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.item?.source == .transcript(fromSegment: nil) }
        model.setTranscriptPaneMode(.chat)
        #expect(model.transcriptPaneMode == .chat)
        await model.openReading()
        #expect(model.transcriptPaneMode == .transcript)
        await model.stopReading()
    }

    @Test("the model hides the control during a take and for a failed reading shows one layout at any width")
    func modelTakeAndFailure() async throws {
        let model = EntryWindowTestSupport.makeModel("now-reading-take")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["One two three four.", "Five six seven eight."], speakers: [nil, nil], audio: nil
        )
        model.loadEntry(entry.id)
        await waitUntil { model.hasTranscript }
        model.readAloud.mockVoice?.install(msPerUnit: 20, failAtUnit: 1)
        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state.name == "failed" }

        #expect(model.nowReadingLayout == .failed)
        model.windowWidthTierForReading = .narrow
        #expect(model.nowReadingLayout == .failed)
        model.installTestTake(source: .microphone)
        #expect(model.nowReadingLayout == .hidden)
    }

    @Test("Use Built-in Voice is offered only when the failed voice is not already the built-in one")
    func builtInOffer() async throws {
        let rig = ReadAloudRig(failAtUnit: 0)
        await rig.controller.start(ReadAloudRig.plan())
        await waitUntil { rig.controller.state.name == "failed" }
        #expect(!rig.controller.canUseBuiltInVoice)

        var other = ReadAloudRig.plan()
        other.voice = try #require(VoiceID.apple(identifier: "com.example.voice"))
        await rig.controller.start(other)
        await waitUntil { rig.controller.state.name == "failed" }
        #expect(rig.controller.canUseBuiltInVoice)
    }

    @Test("the failed control's line is the state's own line")
    func failedLineIsTheStatesOwn() {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("now-reading-line"))
        #expect(NowReadingLayout.resolve(state: .failed("Couldn't open the audio output."), takeActive: false, width: .wide) == .failed)
        #expect(model.readAloud.failureMessage(named: "Maria") == "Couldn't continue with Maria.")
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
