import Foundation
import ParolaCore
import ParolaSpeech
import Testing
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Read Aloud voice chooser")
struct ReadAloudVoiceChooserTests {
    private func makeModel(defaults: UserDefaults? = nil) -> AppModel {
        AppModel(skipBootstrap: true, defaults: defaults ?? temporaryDefaults(), libraryURL: makeTempLibraryURL("voice-chooser"))
    }

    private func load(_ model: AppModel, language: String = "en") {
        model.transcript = Transcript(
            segments: (0..<4).map { TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: "Segment number \($0) says something.") },
            language: language,
            modelName: "stub"
        )
        model.phase = .ready
    }

    private struct StubSource: AudioSource {
        func prepare() async throws -> URL { URL(fileURLWithPath: "/tmp/stub-\(UUID()).wav") }
        func cancel() async {}
        func estimatedDuration() async -> Double? { nil }
    }

    private let premium = VoiceID.apple(identifier: "com.parola.mock.en.premium")!

    @Test("Apple as the only offer reads straight away with apple:auto and saves nothing")
    func appleOnlyReadsStraight() async {
        let model = makeModel()
        load(model)

        let refusal = await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }

        #expect(refusal == nil)
        #expect(model.readAloud.voicePrompt == nil)
        #expect(model.readAloud.item?.voice == .appleAutomatic)
        #expect(model.readAloudVoices.isEmpty)
        await model.stopReading()
    }

    @Test("a saved voice reads, and Use saves the voice and starts the next reading with it")
    func useSavesAndReads() async {
        let defaults = temporaryDefaults()
        let model = makeModel(defaults: defaults)
        load(model)

        model.presentVoiceChooser(for: .transcript)
        let prompt = model.readAloud.voicePrompt
        #expect(prompt?.mode == .choose)
        #expect(prompt?.origin == .main)
        #expect(prompt?.language == "en")

        await model.chooseVoice(premium, for: "en")
        await waitUntil { model.readAloud.state == .reading }

        #expect(model.readAloud.voicePrompt == nil)
        #expect(model.readAloudVoices["en"] == premium)
        #expect(model.readAloud.item?.voice == premium)
        #expect(defaults.string(forKey: "readAloudVoices") == #"{"en":"apple:com.parola.mock.en.premium"}"#)

        await model.stopReading()
        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }
        #expect(model.readAloud.item?.voice == premium)
        #expect(model.readAloud.voicePrompt == nil)
        await model.stopReading()

        let reloaded = makeModel(defaults: defaults)
        #expect(reloaded.readAloudVoices["en"] == premium)
    }

    @Test("Close saves nothing and starts nothing")
    func closeSavesNothing() async {
        let model = makeModel()
        load(model)
        model.presentVoiceChooser(for: .transcript)

        model.dismissVoicePrompt()

        #expect(model.readAloud.voicePrompt == nil)
        #expect(model.readAloudVoices.isEmpty)
        #expect(model.readAloud.state == .idle)
    }

    @Test("the built-in voice for now reads with apple:auto and saves nothing")
    func builtInForNow() async {
        let model = makeModel()
        load(model)
        model.presentVoiceChooser(for: .transcript)

        await model.readWithBuiltInVoiceForNow()
        await waitUntil { model.readAloud.state == .reading }

        #expect(model.readAloud.voicePrompt == nil)
        #expect(model.readAloudVoices.isEmpty)
        #expect(model.readAloud.item?.voice == .appleAutomatic)
        await model.stopReading()
    }

    @Test("opening the chooser leaves a playing reading playing")
    func openingLeavesReading() async {
        let model = makeModel()
        load(model)
        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }

        model.presentVoiceChooser(for: .transcript)

        #expect(model.readAloud.voicePrompt != nil)
        #expect(model.readAloud.state == .reading)
        model.dismissVoicePrompt()
        await model.stopReading()
    }

    @Test("a saved voice that is gone leads to the chooser instead of reading")
    func goneVoiceLeadsToChooser() async {
        let model = makeModel()
        load(model)
        model.readAloudVoices["en"] = VoiceID.apple(identifier: "com.parola.mock.en.removed")

        let refusal = await model.readAloud(ReadAloudRequest(kind: .transcript))

        #expect(refusal == .needsVoice)
        #expect(model.readAloud.voicePrompt?.mode == .choose)
        #expect(model.readAloud.voicePrompt?.request == ReadAloudRequest(kind: .transcript))
        #expect(model.readAloud.state == .idle)
    }

    @Test("a saved voice marked unusable counts as gone")
    func unusableVoiceLeadsToChooser() async {
        let model = makeModel()
        load(model)
        model.readAloudVoices["en"] = premium
        model.readAloud.mockVoice?.unusableVoices = [premium.rawValue.replacingOccurrences(of: "apple:", with: "")]

        #expect(await model.readAloud(ReadAloudRequest(kind: .transcript)) == .needsVoice)
        #expect(model.voiceDecision(for: "en") == .chooser)
    }

    @Test("a language no voice reads opens the chooser in its no-voice state and plays nothing")
    func noVoiceState() async {
        let model = makeModel()
        load(model, language: "fa")

        let refusal = await model.readAloud(ReadAloudRequest(kind: .transcript))

        #expect(refusal == .noVoice)
        #expect(model.readAloud.state == .noVoice("fa"))
        #expect(model.readAloud.voicePrompt?.mode == .noVoice)
        #expect(model.readAloud.voicePrompt?.language == "fa")
        #expect(ReadAloudVoices.menuEntries(for: "fa", in: model.readAloud.appleInventory).isEmpty)

        model.dismissVoicePrompt()
        await model.readAloud(ReadAloudRequest(kind: .transcript))
        #expect(model.readAloud.voicePrompt?.mode == .noVoice)
    }

    @Test("the no-voice state replaces a reading that was playing, in another language")
    func noVoiceStopsReading() async {
        let model = makeModel()
        load(model)
        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }

        load(model, language: "fa")
        await model.readAloud(ReadAloudRequest(kind: .transcript))

        #expect(model.readAloud.state == .noVoice("fa"))
    }

    @Test("Choose Voice on a language with no voice opens the no-voice state")
    func chooseVoiceOnNoVoiceLanguage() {
        let model = makeModel()
        load(model, language: "fa")

        model.presentVoiceChooser(for: .transcript)

        #expect(model.readAloud.voicePrompt?.mode == .noVoice)
    }

    @Test("Preview pauses a playing reading, and is refused while a take blocks reading")
    func previewPausesAndRefuses() async {
        let model = makeModel()
        load(model)
        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }

        let started = await model.previewVoice(premium, language: "en")

        #expect(started)
        #expect(model.readAloud.state == .paused(.user))
        #expect(model.readAloud.previewing == premium)
        await model.readAloud.stopPreview()
        #expect(model.readAloud.previewing == nil)
        #expect(model.readAloud.state == .paused(.user))

        model.installTestTake(source: .microphone, liveSource: StubSource())
        await waitUntil { model.readAloud.state == .paused(.take) }
        #expect(await model.previewVoice(premium, language: "en") == false)
        #expect(model.readAloud.previewing == nil)
        model.endTestTake()
        await model.stopReading()
    }

    @Test("Resume stops a preview before the reading goes on")
    func resumeStopsPreview() async {
        let model = makeModel()
        load(model)
        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }
        await model.previewVoice(premium, language: "en")

        await model.resumeReading()

        #expect(model.readAloud.previewing == nil)
        #expect(model.readAloud.state == .reading)
        await model.stopReading()
    }

    @Test("a failed reading names the voice, in English and Italian")
    func failureReason() async throws {
        let model = makeModel()
        load(model)
        model.readAloudVoices["en"] = premium
        model.readAloud.mockVoice?.install(msPerUnit: 20, failAtUnit: 1)

        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { if case .failed = model.readAloud.state { true } else { false } }

        guard case .failed(let message) = model.readAloud.state else {
            Issue.record("expected a failed reading")
            return
        }
        #expect(message == "Couldn't continue with Mock Premium.")
        let status = ReadAloudButtonStatus.resolve(state: model.readAloud.state, readsThis: true, blocked: nil, hasContent: true)
        #expect(status.failureMessage == message)

        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        let template = italian.localizedString(forKey: "Couldn't continue with %@.", value: "MISSING", table: nil)
        #expect(String(format: template, "Mock Premium") == "Impossibile continuare con Mock Premium.")
        await model.stopReading()
    }

    @Test("the chooser title and no-voice line carry the language name, lowercase in Italian")
    func languageNamesInCopy() throws {
        #expect(LanguageDisplay.midSentenceName(for: "fa", locale: Locale(identifier: "en_US")) == "Persian")
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        let title = italian.localizedString(forKey: "Choose a voice to read %@", value: "MISSING", table: nil)
        let name = try #require(LanguageDisplay.midSentenceName(for: "fa", locale: Locale(identifier: "it_IT")))
        #expect(String(format: title, name) == "Scegli una voce per leggere in persiano")
        let none = italian.localizedString(forKey: "No voice on this Mac reads %@.", value: "MISSING", table: nil)
        #expect(String(format: none, name) == "Nessuna voce su questo Mac legge in persiano.")
    }

    @Test("Get more voices opens the speech anchor first")
    func moreVoices() {
        let model = makeModel()
        #expect(model.openMoreVoices())
        #expect(model.readAloud.mockVoice?.openedURLs.map(\.absoluteString) == [
            "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?AX_SPEECH_VOICES",
        ])
    }

    @Test("a language row appears for the interface language, the library, the saved choices and the open translation")
    func settingsRows() {
        let model = makeModel()
        model.readAloudVoices["fr"] = .appleAutomatic
        let rows = ReadAloudVoices.rows(
            known: model.knownLanguages(in: nil), saved: Array(model.readAloudVoices.keys),
            interface: "en", translations: []
        )
        #expect(rows.contains("fr"))
        #expect(rows.contains("en"))
    }

    @Test("Settings: the pane has a route, keys, a reset that clears them, and search keywords")
    func settingsPane() {
        #expect(SettingsRoute.readAloud.paneScope == .readAloud)
        #expect(SettingsRoute.readAloud.label == "Read Aloud")
        #expect(SettingsRoute.readAloud.symbol == "speaker.wave.2")
        #expect(SettingsRoute.readAloud.summary == "The voice Parola reads with, one for each language.")
        let groups = SettingsSidebarCatalog.all
        let transcription = groups.first { $0.id == "transcription" }?.routes ?? []
        let translation = transcription.firstIndex(of: .translation)
        #expect(translation != nil && transcription.firstIndex(of: .readAloud) == translation.map { $0 + 1 })
        #expect(SettingsPaneScope.readAloud.defaultsKeys == ["readAloudVoices", "readAloudRate"])
        for query in ["voice", "speak", "tts", "text to speech", "premium", "enhanced", "voce", "sintesi vocale", "read aloud"] {
            #expect(SettingsSidebarCatalog.matches(route: .readAloud, query: query), "search for \(query)")
        }
    }

    @Test("Reset clears the saved voices and the speed, and the model reads them back as defaults")
    func settingsReset() {
        let defaults = temporaryDefaults()
        let model = makeModel(defaults: defaults)
        model.readAloudVoices["it"] = .appleAutomatic
        model.setReadingSpeed(1.5)
        #expect(defaults.string(forKey: "readAloudVoices") != nil)

        for key in SettingsPaneScope.readAloud.resetKeys(features: .all) { defaults.removeObject(forKey: key) }
        model.reloadObservedSetting(key: "readAloudVoices")

        #expect(model.readAloudVoices.isEmpty)
        #expect(model.readAloudRate == 1)
    }

    @Test("the bridge can write the saved voices and the speed")
    func bridgeKeys() {
        #expect(ParolaAutomationServer.writableSettingKeys.contains("readAloudVoices"))
        #expect(ParolaAutomationServer.writableSettingKeys.contains("readAloudRate"))
    }

    @Test("the Personal Voice request is a seam: the mock never prompts, and reports its status")
    func personalVoiceSeam() async {
        let model = makeModel()
        #expect(model.readAloud.personalVoiceStatus == .notDetermined)
        model.readAloud.mockVoice?.personalVoiceStatus = .denied
        await model.requestPersonalVoice()
        #expect(model.readAloud.personalVoiceStatus == .denied)
    }
}
