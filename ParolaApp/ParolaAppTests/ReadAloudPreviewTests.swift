import Foundation
import ParolaCore
import ParolaSpeech
import Testing
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Read Aloud preview")
struct ReadAloudPreviewTests {
    private let voice = VoiceID.appleAutomatic

    @Test("a block that starts during a preview stops it at once, with nothing reading")
    func blockStopsPreviewIdle() async {
        let rig = ReadAloudRig()
        #expect(await rig.controller.preview(voice, language: "en"))
        #expect(rig.controller.previewing == voice)

        rig.blocked = .take
        rig.controller.focusChanged()

        #expect(rig.controller.previewing == nil)
        await settle()
        let scheduled = rig.sink.scheduledCount
        await settle()
        #expect(rig.sink.scheduledCount == scheduled)
        #expect(rig.sink.stopCount > 0)
    }

    @Test("a block that starts during a preview stops it, and the paused reading stays paused")
    func blockStopsPreviewWhileReading() async {
        let rig = ReadAloudRig()
        await rig.start()
        #expect(await rig.controller.preview(voice, language: "en"))

        rig.blocked = .dictation
        rig.controller.focusChanged()

        #expect(rig.controller.previewing == nil)
        #expect(rig.controller.state == .paused(.dictation))
        await settle()
        let scheduled = rig.sink.scheduledCount
        await settle()
        #expect(rig.sink.scheduledCount == scheduled)
    }

    @Test("media starting stops a preview too")
    func mediaStopsPreview() async {
        let rig = ReadAloudRig()
        await rig.start()
        await rig.controller.pause()
        #expect(await rig.controller.preview(voice, language: "en"))

        rig.controller.mediaStartedPlaying()

        #expect(rig.controller.previewing == nil)
        #expect(rig.controller.state == .paused(.media))
    }

    @Test("a preview refuses when blocked at the start, and when a block lands during the pause")
    func eachBlockedGuard() async {
        let rig = ReadAloudRig()
        rig.blocked = .take
        #expect(await rig.controller.preview(voice, language: "en") == false)
        #expect(rig.controller.previewing == nil)

        rig.blocked = nil
        let later = ReadAloudRig()
        later.blockedFromRead = later.blockedReads + 2
        #expect(await later.controller.preview(voice, language: "en") == false)
        #expect(later.controller.previewing == nil)
    }

    @Test("stop and start both end a preview")
    func stopAndStartEndPreview() async {
        let rig = ReadAloudRig()
        #expect(await rig.controller.preview(voice, language: "en"))
        await rig.controller.stop()
        #expect(rig.controller.previewing == nil)

        #expect(await rig.controller.preview(voice, language: "en"))
        await rig.controller.start(ReadAloudRig.plan())
        #expect(rig.controller.previewing == nil)
        await rig.controller.stop()
    }

    @Test("a preview pauses a playing entry player")
    func previewPausesPlayers() async {
        let rig = ReadAloudRig()
        let log = PlayerLog()
        rig.players = [log.handle(playing: true)]

        #expect(await rig.controller.preview(voice, language: "en"))

        #expect(log.pauses == 1)
        await rig.controller.stopPreview()
    }

    @Test("a language with no sample previews the transcript's own sentence when it has four words, else English")
    func sampleText() {
        #expect(ReadAloudVoices.sampleText(for: "it", transcriptSentence: "Una frase diversa dal solito.") == "Così leggerò la tua trascrizione.")
        #expect(ReadAloudVoices.sampleText(for: "fa", transcriptSentence: "این یک جمله آزمایشی است") == "این یک جمله آزمایشی است")
        #expect(ReadAloudVoices.sampleText(for: "fa", transcriptSentence: "یک دو سه") == ReadAloudVoices.sampleSentence(for: "en"))
        #expect(ReadAloudVoices.sampleText(for: "fa", transcriptSentence: nil) == ReadAloudVoices.sampleSentence(for: "en"))
    }

    @Test("a saved voice that isn't installed shows as not installed in the Settings pop-up")
    func settingsEntries() {
        let inventory = AppleVoiceInventory(
            voices: [VoiceDescriptor(identifier: "a.it", name: "Alice", language: "it-IT", quality: .default, isNovelty: false, isPersonal: false, family: .standard)],
            unusable: []
        )
        let gone = VoiceID.apple(identifier: "a.gone")!
        let entries = ReadAloudVoices.settingsEntries(for: "it", in: inventory, saved: gone)
        #expect(entries.first?.title == "Voice not installed")
        #expect(entries.first?.voice == gone)
        #expect(entries.first?.isUsable == false)
        #expect(ReadAloudVoices.settingsEntries(for: "it", in: inventory, saved: VoiceID.apple(identifier: "a.it")!).first?.voice == .appleAutomatic)
        #expect(ReadAloudVoices.settingsEntries(for: "it", in: inventory, saved: nil).count == 2)
    }

    @Test("a refresh of the voices is something the views can observe")
    func voicesRevision() {
        let rig = ReadAloudRig()
        let before = rig.controller.voicesRevision
        rig.controller.refreshVoices()
        #expect(rig.controller.voicesRevision == before + 1)
    }

    @Test("the denied Personal Voice copy reads in English and Italian")
    func deniedCopy() throws {
        let key = "Parola can't use your Personal Voice. Allow it in System Settings, under Privacy & Security."
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        #expect(italian.localizedString(forKey: key, value: "MISSING", table: nil)
            == "Parola non può usare la tua voce personale. Consentilo in Impostazioni di Sistema, sotto Privacy e sicurezza.")
        #expect(String(localized: "Parola can't use your Personal Voice. Allow it in System Settings, under Privacy & Security.") == key)
    }

    @Test("the new Italian strings are in")
    func italianStrings() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        let keys: [(String, String)] = [
            ("No voice reads %@", "Nessuna voce legge in %@"),
            ("Voice not installed", "Voce non installata"),
            ("Built-in voice", "Voce integrata"),
            ("Playback", "Riproduzione"),
            ("%@ · Enhanced", "%@ · Migliorata"),
        ]
        for (key, expected) in keys {
            #expect(italian.localizedString(forKey: key, value: "MISSING", table: nil) == expected, "\(key)")
        }
    }

    @Test("the reading names the voice that was chosen when it started, for Automatic too")
    func voiceNameCaptured() async {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("preview"))
        model.transcript = Transcript(
            segments: (0..<4).map { TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: "Segment \($0) says something.") },
            language: "en", modelName: "stub"
        )
        model.phase = .ready
        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }
        #expect(model.readAloud.item?.voiceName == "Mock Premium")
        await model.stopReading()
    }

    @Test("Try Again after a saved voice was marked unusable opens the chooser instead of retrying it")
    func retryOpensChooser() async {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("retry"))
        model.transcript = Transcript(
            segments: (0..<4).map { TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: "Segment \($0) says something.") },
            language: "en", modelName: "stub"
        )
        model.phase = .ready
        let saved = VoiceID.apple(identifier: "com.parola.mock.en.premium")!
        model.readAloudVoices["en"] = saved
        model.readAloud.mockVoice?.install(msPerUnit: 20, failAtUnit: 2)
        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { if case .failed = model.readAloud.state { true } else { false } }

        model.readAloud.mockVoice?.unusableVoices = ["com.parola.mock.en.premium"]
        await model.retryReading()

        #expect(model.readAloud.voicePrompt?.mode == .choose)
        #expect(model.readAloud.voicePrompt?.request == ReadAloudRequest(kind: .transcript, fromSegment: 2))
        #expect(model.readAloud.state != .reading)
    }

    @Test("Try Again with a voice that still works retries it")
    func retryStillRetries() async {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("retry2"))
        model.transcript = Transcript(
            segments: (0..<4).map { TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: "Segment \($0) says something.") },
            language: "en", modelName: "stub"
        )
        model.phase = .ready
        model.readAloud.mockVoice?.install(msPerUnit: 20, failAtUnit: 2)
        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { if case .failed = model.readAloud.state { true } else { false } }

        model.readAloud.mockVoice?.clear()
        await model.retryReading()

        #expect(model.readAloud.voicePrompt == nil)
        await model.stopReading()
    }
}
