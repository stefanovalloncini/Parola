import Foundation
import ParolaCore
import ParolaSpeech
import Testing
@testable import Parola

private func voice(
    _ id: String, _ name: String, _ language: String, _ quality: VoiceDescriptor.Quality = .default, personal: Bool = false
) -> VoiceDescriptor {
    VoiceDescriptor(
        identifier: id, name: name, language: language, quality: quality, isNovelty: false, isPersonal: personal,
        family: .standard
    )
}

private let italian = VoiceID.apple(identifier: "com.test.it.federica")!

@Suite("Read Aloud voices")
struct ReadAloudVoicesTests {
    @Test("the chooser trigger is a function of the saved choice, the neural offers and the Apple voices")
    func triggerTable() {
        typealias Row = (saved: VoiceID?, usable: Bool, neural: Bool, apple: Bool, expected: ReadAloudVoiceDecision)
        let rows: [Row] = [
            (nil, false, false, true, .read(.appleAutomatic)),
            (italian, true, false, true, .read(italian)),
            (italian, true, true, true, .read(italian)),
            (.appleAutomatic, true, true, true, .read(.appleAutomatic)),
            (nil, false, true, true, .chooser),
            (nil, false, true, false, .chooser),
            (italian, false, false, true, .chooser),
            (italian, false, true, true, .chooser),
            (nil, false, false, false, .noVoice),
            (italian, false, false, false, .noVoice),
        ]
        for row in rows {
            let decision = ReadAloudVoices.decide(
                saved: row.saved, savedIsUsable: row.usable, neuralOffers: row.neural, appleVoices: row.apple
            )
            #expect(decision == row.expected, "saved \(String(describing: row.saved)) usable \(row.usable) neural \(row.neural) apple \(row.apple)")
        }
    }

    @Test("no neural pack offers anything yet")
    func noNeuralOffers() {
        for language in ["en", "it", "fr", "yue", "fa"] {
            #expect(ReadAloudVoices.neuralOffers(for: language).isEmpty)
        }
    }

    @Test("a saved voice counts only when it is installed for that language and not marked unusable")
    func usability() {
        let inventory = AppleVoiceInventory(
            voices: [voice("a.it", "Federica", "it-IT", .premium), voice("a.en", "Ava", "en-US"), voice("a.hk", "Sinji", "zh-HK")],
            unusable: ["a.bad"]
        )
        #expect(ReadAloudVoices.isUsable(.appleAutomatic, for: "it", in: inventory))
        #expect(ReadAloudVoices.isUsable(.apple(identifier: "a.it")!, for: "it-IT", in: inventory))
        #expect(!ReadAloudVoices.isUsable(.apple(identifier: "a.en")!, for: "it", in: inventory))
        #expect(!ReadAloudVoices.isUsable(.apple(identifier: "gone")!, for: "it", in: inventory))
        #expect(!ReadAloudVoices.isUsable(.appleAutomatic, for: "fa", in: inventory))
        #expect(ReadAloudVoices.isUsable(.apple(identifier: "a.hk")!, for: "yue", in: inventory))
        #expect(!ReadAloudVoices.isUsable(.neural(pack: "pocket-tts-italian", voice: "giovanni")!, for: "it", in: inventory))

        let marked = AppleVoiceInventory(voices: inventory.voices, unusable: ["a.it"])
        #expect(!ReadAloudVoices.isUsable(.apple(identifier: "a.it")!, for: "it", in: marked))
        #expect(!ReadAloudVoices.isUsable(.appleAutomatic, for: "it", in: marked))
    }

    @Test("the pop-up starts with Automatic, then ranked voices, then the ones that can't read")
    func menuEntries() {
        let inventory = AppleVoiceInventory(
            voices: [
                voice("a.compact", "Alice", "it-IT"),
                voice("a.premium", "Federica", "it-IT", .premium),
                voice("a.enhanced", "Emma", "it-IT", .enhanced),
                voice("a.bad", "Cosimo", "it-IT", .premium),
                voice("a.en", "Ava", "en-US"),
            ],
            unusable: ["a.bad"]
        )
        let entries = ReadAloudVoices.menuEntries(for: "it", in: inventory)
        #expect(entries.map(\.voice.rawValue) == [
            "apple:auto", "apple:a.premium", "apple:a.enhanced", "apple:a.compact", "apple:a.bad",
        ])
        #expect(entries.map(\.isUsable) == [true, true, true, true, false])
        #expect(entries[0].title == "Automatic (best installed)")
        #expect(entries[1].title == "Federica · Premium")
        #expect(entries[2].title == "Emma · Enhanced")
        #expect(entries[3].title == "Alice")
        #expect(entries[4].title == "Cosimo · Can't read aloud with this voice.")
    }

    @Test("a language with no Apple voice has no Built-in entries")
    func noAppleVoice() {
        let inventory = AppleVoiceInventory(voices: [voice("a.en", "Ava", "en-US")], unusable: [])
        #expect(ReadAloudVoices.menuEntries(for: "fa", in: inventory).isEmpty)
        #expect(!ReadAloudVoices.hasAppleVoice(for: "fa", in: inventory))
        let allBad = AppleVoiceInventory(voices: [voice("a.en", "Ava", "en-US")], unusable: ["a.en"])
        #expect(ReadAloudVoices.menuEntries(for: "en", in: allBad).isEmpty)
    }

    @Test("Personal Voice shows in the pop-up under its own badge")
    func personalVoiceEntry() {
        let inventory = AppleVoiceInventory(
            voices: [voice("a.mine", "My Voice", "it-IT", .default, personal: true), voice("a.it", "Alice", "it-IT")],
            unusable: []
        )
        let titles = ReadAloudVoices.menuEntries(for: "it", in: inventory).map(\.title)
        #expect(titles == ["Automatic (best installed)", "My Voice · Personal Voice", "Alice"])
    }

    @Test("the Settings rows join the library, the saved choices, the interface and the translation targets")
    func languageRows() {
        let rows = ReadAloudVoices.rows(
            known: ["IT", "en", "unknown"], saved: ["fr", "en"], interface: "it-IT", translations: ["de", "EN-GB", ""]
        )
        #expect(Set(rows) == ["it", "en", "fr", "de"])
        #expect(rows.count == 4)
    }

    @Test("the Personal Voice section follows the authorisation status")
    func personalVoiceRule() {
        #expect(ReadAloudVoices.personalVoice(status: .unsupported, personalVoices: 0) == .hidden)
        #expect(ReadAloudVoices.personalVoice(status: .notDetermined, personalVoices: 0) == .askButton)
        #expect(ReadAloudVoices.personalVoice(status: .denied, personalVoices: 0) == .deniedNote)
        #expect(ReadAloudVoices.personalVoice(status: .authorized, personalVoices: 2) == .granted(voices: 2))
    }

    @Test("Get more voices tries the speech anchor, then spoken content, then the bare pane")
    func moreVoicesOrder() {
        let urls = ReadAloudVoices.systemSettingsURLs.map(\.absoluteString)
        #expect(urls == [
            "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?AX_SPEECH_VOICES",
            "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?AX_FEATURE_SPOKENCONTENT",
            "x-apple.systempreferences:com.apple.Accessibility-Settings.extension",
        ])
    }

    @Test("saved voices round-trip as JSON keyed by base language, and bad entries are dropped")
    func savedCodec() throws {
        let saved: [String: VoiceID] = ["it": italian, "en": .appleAutomatic]
        let json = try #require(ReadAloudVoices.encodeSaved(saved))
        #expect(json == #"{"en":"apple:auto","it":"apple:com.test.it.federica"}"#)
        #expect(ReadAloudVoices.decodeSaved(json) == saved)
        #expect(ReadAloudVoices.decodeSaved(#"{"en-GB":"apple:auto","fr":"nonsense","yue":"apple:x"}"#)
            == ["en": .appleAutomatic, "yue": VoiceID.apple(identifier: "x")!])
        #expect(ReadAloudVoices.decodeSaved("not json").isEmpty)
        #expect(ReadAloudVoices.decodeSaved(nil).isEmpty)
        #expect(ReadAloudVoices.encodeSaved([:]) == nil)
    }

    @Test("the keys follow the base language and keep yue apart from zh")
    func keys() {
        #expect(ReadAloudVoices.key(for: "en-GB") == "en")
        #expect(ReadAloudVoices.key(for: "zh-Hant") == "zh")
        #expect(ReadAloudVoices.key(for: "yue") == "yue")
    }

    @Test("the sample sentence is fixed per language, free of digits, and English when a language has none")
    func sampleSentence() {
        for (language, text) in ReadAloudVoices.sampleSentences {
            #expect(!text.contains { $0.isNumber }, "digits in the \(language) sample")
        }
        #expect(ReadAloudVoices.sampleSentence(for: "it-IT") == "Così leggerò la tua trascrizione.")
        #expect(ReadAloudVoices.sampleSentence(for: "fa") == ReadAloudVoices.sampleSentence(for: "en"))
    }

    @Test("the failure line names the voice, and names the best installed one for Automatic")
    func failureLine() {
        let inventory = AppleVoiceInventory(
            voices: [voice("a.it", "Federica", "it-IT", .premium), voice("a.alice", "Alice", "it-IT")], unusable: []
        )
        #expect(ReadAloudVoices.spokenName(of: .appleAutomatic, language: "it", in: inventory) == "Federica")
        #expect(ReadAloudVoices.spokenName(of: .apple(identifier: "a.alice")!, language: "it", in: inventory) == "Alice")
        #expect(ReadAloudVoices.spokenName(of: .appleAutomatic, language: "fa", in: inventory) == "the built-in voice")
    }

    @Test("the new strings read in English and Italian")
    func italianStrings() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        let keys: [(String, String)] = [
            ("Choose a voice to read %@", "Scegli una voce per leggere in %@"),
            ("No voice on this Mac reads %@.", "Nessuna voce su questo Mac legge in %@."),
            ("Built into macOS. Ready now.", "Integrato in macOS. Pronto subito."),
            ("Use the built-in voice for now", "Usa la voce integrata per ora"),
            ("Couldn't continue with %@.", "Impossibile continuare con %@."),
            ("Choose Voice…", "Scegli la voce…"),
            ("Get more voices…", "Scarica altre voci…"),
            ("Automatic (best installed)", "Automatica (la migliore installata)"),
            ("Read Aloud", "Leggi ad alta voce"),
            ("The voice Parola reads with, one for each language.", "La voce con cui Parola legge, una per ogni lingua."),
        ]
        for (key, expected) in keys {
            #expect(italian.localizedString(forKey: key, value: "MISSING", table: nil) == expected, "Italian for \(key)")
        }
    }
}
