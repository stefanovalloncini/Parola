import Foundation
import ParolaCore
import Testing
@testable import Parola

@MainActor
@Suite("Read Aloud button states")
struct ReadAloudButtonStatusTests {
    private func resolve(
        _ state: ReadAloudController.State,
        readsThis: Bool = true,
        blocked: ReadAloudController.BlockedReason? = nil,
        hasContent: Bool = true
    ) -> ReadAloudButtonStatus {
        ReadAloudButtonStatus.resolve(state: state, readsThis: readsThis, blocked: blocked, hasContent: hasContent)
    }

    @Test("reading pauses, paused and waiting resume, preparing does nothing, failed retries, otherwise start")
    func stateTable() {
        #expect(resolve(.reading).action == .pause)
        #expect(resolve(.reading).symbol == "speaker.wave.2.fill")
        #expect(resolve(.paused(.user)).action == .resume)
        #expect(resolve(.paused(.take)).symbol == "speaker.wave.2.fill")
        #expect(resolve(.waiting(.slow)).action == .resume)
        #expect(resolve(.preparing).action == .none)
        #expect(resolve(.preparing).isEnabled == false)
        #expect(resolve(.failed("x")).action == .retry)
        #expect(resolve(.failed("x")).symbol == "speaker.wave.2")
        #expect(resolve(.idle).action == .start)
        #expect(resolve(.noVoice("fa")).action == .start)
        #expect(resolve(.idle).symbol == "speaker.wave.2")
    }

    @Test("another entry or source shows the idle button, replacing the current reading")
    func otherEntryStartsNew() {
        for state in [ReadAloudController.State.reading, .paused(.user), .preparing, .failed("x")] {
            let status = resolve(state, readsThis: false)
            #expect(status.action == .start)
            #expect(status.titleKey == "Read aloud")
        }
    }

    @Test("a take, dictation or captions disable reading but not pause")
    func blockingDisables() {
        for blocked in [ReadAloudController.BlockedReason.take, .dictation, .captions] {
            #expect(resolve(.idle, blocked: blocked).isEnabled == false)
            #expect(resolve(.idle, blocked: blocked).blockedMessage == blocked.message)
            #expect(resolve(.paused(.take), blocked: blocked).isEnabled == false)
            #expect(resolve(.failed("x"), blocked: blocked).isEnabled == false)
            #expect(resolve(.reading, blocked: blocked).isEnabled)
            #expect(resolve(.reading, blocked: blocked).blockedMessage == nil)
        }
    }

    @Test("nothing to read leaves the start button off")
    func noContent() {
        #expect(resolve(.idle, hasContent: false).isEnabled == false)
        #expect(resolve(.idle, hasContent: true).isEnabled)
    }

    @Test("labels and the blocked reasons read in English and Italian")
    func localized() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        let keys: [(String, String)] = [
            ("Pause reading", "Metti in pausa la lettura"),
            ("Resume reading", "Riprendi la lettura"),
            ("Preparing…", "Preparazione…"),
            ("Try again", "Riprova"),
            ("Read aloud", "Leggi ad alta voce"),
            ("Reading waits until the recording ends.", "La lettura riprende quando finisce la registrazione."),
            ("Reading waits until dictation ends.", "La lettura riprende quando finisce la dettatura."),
            ("Reading waits until live captions stop.", "La lettura riprende quando si fermano i sottotitoli in tempo reale."),
            ("Read from Current Segment", "Leggi dal segmento corrente"),
            ("Read Aloud from Here", "Leggi ad alta voce da qui"),
            ("Translated to %@", "Tradotto in %@"),
            ("Read Translation (%@)", "Leggi la traduzione (%@)"),
            ("Couldn't read this aloud.", "Impossibile leggere ad alta voce."),
            ("Couldn't open the audio output.", "Impossibile aprire l'uscita audio."),
        ]
        for (key, expected) in keys {
            #expect(italian.localizedString(forKey: key, value: "MISSING", table: nil) == expected, "Italian for \(key)")
        }
    }

    @Test("the blocked messages are the controller's own strings")
    func blockedMessages() {
        #expect(ReadAloudController.BlockedReason.take.message == "Reading waits until the recording ends.")
        #expect(ReadAloudController.BlockedReason.dictation.message == "Reading waits until dictation ends.")
        #expect(ReadAloudController.BlockedReason.captions.message == "Reading waits until live captions stop.")
    }
}
