import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("Failure text", .timeLimit(.minutes(1)))
struct FailureTextTests {
    private func bundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    private struct Unlisted: LocalizedError {
        var errorDescription: String? { "Something only the system knows." }
    }

    @Test("ParolaError cases read in Italian")
    func parolaErrors() throws {
        let it = try bundle("it")
        let file = URL(fileURLWithPath: "/tmp/riunione.m4a")
        #expect(FailureText.message(for: ParolaError.unknownModel("smal", suggestion: "small"), bundle: it)
            == "Modello “smal” sconosciuto. Intendevi “small”?")
        #expect(FailureText.message(for: ParolaError.fileMissing(file), bundle: it) == "Parola non è riuscita a trovare riunione.m4a.")
        #expect(FailureText.message(for: ParolaError.fileReadTimedOut(name: "a.m4a"), bundle: it)
            == "Parola non è riuscita a leggere a.m4a in tempo.")
        #expect(FailureText.message(for: ParolaError.transcriptionFailed("WhisperKit returned no results"), bundle: it)
            == "Trascrizione non riuscita: Il modello non ha restituito alcun testo.")
        #expect(FailureText.message(for: ParolaError.invalidLanguage("xx"), bundle: it) == "Codice lingua non valido: xx")
        #expect(FailureText.message(for: ParolaError.featureDisabled(.liveCaptions), bundle: it)
            == "Funzione disattivata dalla tua organizzazione: Sottotitoli in tempo reale.")
        #expect(FailureText.message(for: ParolaError.policyRestricted(FixedFailureText.modelDownloadsDisabled), bundle: it)
            == "La tua organizzazione ha disattivato il download dei modelli.")
    }

    @Test("the model and microphone sentences point at iOS Settings")
    func platformWording() throws {
        let it = try bundle("it")
        #expect(FailureText.message(for: ParolaError.modelNotFound("small"), bundle: it)
            == "Il modello small non è ancora stato scaricato. Scaricalo da Impostazioni › Modelli sul dispositivo.")
        #expect(FailureText.message(for: ParolaError.captureUnavailable(FixedFailureText.microphoneUnavailable), bundle: it)
            == "Registrazione audio non disponibile: Il microfono non è disponibile. Controlla che Parola possa usarlo in Impostazioni → Privacy e sicurezza → Microfono.")
    }

    @Test("an interrupted capture reads in Italian")
    func captureInterrupted() throws {
        let it = try bundle("it")
        let error = CaptureInterrupted(url: URL(fileURLWithPath: "/tmp/take.caf"), reason: "Disco pieno")
        #expect(FailureText.message(for: error, bundle: it)
            == "Il salvataggio della registrazione si è interrotto (Disco pieno). La parte già salvata si trova in /tmp/take.caf.")
    }

    @Test("AI and library failures read in Italian")
    func aiAndLibrary() throws {
        let it = try bundle("it")
        #expect(FailureText.message(for: CloudLLMError.missingAPIKey(.openAI), bundle: it) == "Nessuna chiave API configurata per OpenAI.")
        #expect(FailureText.message(for: LanguageModelFactory.Failure.notAvailable(FixedFailureText.appleIntelligenceUnavailable), bundle: it)
            == "Apple Intelligence non è disponibile al momento.")
        #expect(FailureText.message(for: SummaryService.FailureReason.modelError(FixedFailureText.appleIntelligenceOff), bundle: it)
            == "Riepilogo non riuscito: Apple Intelligence è disattivata. Attivala in Impostazioni per usare questa funzione.")
        #expect(FailureText.message(for: TranscriptChatSession.FailureReason.modelError("Boom"), bundle: it) == "Chat non riuscita: Boom")
        #expect(FailureText.message(for: LibraryStore.LibraryError.inTrash("x"), bundle: it)
            == "Questa trascrizione è in Eliminati di recente. Ripristinala per aprirla.")
        #expect(FailureText.message(for: LibraryStore.LibraryError.notFound("x"), bundle: it) == "Questa trascrizione non è nella libreria.")
        #expect(FailureText.message(for: CardMetadataService.Failure.tooShort, bundle: it)
            == "La trascrizione è troppo corta per un titolo e un riepilogo.")
    }

    @Test("an error it doesn't know keeps its own description")
    func unknownFallback() throws {
        let it = try bundle("it")
        #expect(FailureText.message(for: Unlisted(), bundle: it) == "Something only the system knows.")
        #expect(FailureText.reason("Something Core never says.", bundle: it) == "Something Core never says.")
    }

    @Test("English keeps the wording Core used")
    func englishMatchesCore() throws {
        let en = try bundle("en")
        let errors: [any Error] = [
            ParolaError.featureDisabled(.batch),
            ParolaError.invalidLanguage("xx"),
            ParolaError.fileMissing(URL(fileURLWithPath: "/tmp/a.m4a")),
            ParolaError.transcriptionFailed("boom"),
            CloudLLMError.disabledByPolicy,
            SummaryService.FailureReason.modelError("boom"),
            LibraryStore.LibraryError.inTrash("x"),
        ]
        for error in errors {
            #expect(FailureText.message(for: error, bundle: en) == error.localizedDescription)
        }
    }
}
