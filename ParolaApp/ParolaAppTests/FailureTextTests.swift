import Foundation
import Testing
@testable import Parola
import ParolaCore
#if canImport(FoundationModels)
import FoundationModels
#endif

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
        #expect(FailureText.message(for: ParolaError.modelNotFound("small"), bundle: it)
            == "Il modello small non è ancora scaricato. Scaricalo da Impostazioni › Modelli locali.")
        #expect(FailureText.message(for: ParolaError.unknownModel("smal", suggestion: "small"), bundle: it)
            == "Modello “smal” sconosciuto. Intendevi “small”?")
        #expect(FailureText.message(for: ParolaError.featureDisabled(.batch), bundle: it)
            == "Disattivato in questa installazione: Trascrizione in batch.")
        #expect(FailureText.message(for: ParolaError.fileMissing(file), bundle: it)
            == "Parola non è riuscita a trovare riunione.m4a.")
        #expect(FailureText.message(for: ParolaError.audioLoadFailed(file, underlying: "x"), bundle: it)
            == "Parola non è riuscita a caricare l'audio da riunione.m4a.")
        #expect(FailureText.message(for: ParolaError.unreadableFile(name: "a.m4a", reason: "The file is empty."), bundle: it)
            == "Parola non è riuscita a leggere a.m4a. Il file è vuoto.")
        #expect(FailureText.message(for: ParolaError.fileReadTimedOut(name: "a.m4a"), bundle: it)
            == "Parola non è riuscita a leggere a.m4a in tempo.")
        #expect(FailureText.message(for: ParolaError.transcriptionFailed("WhisperKit returned no results"), bundle: it)
            == "Trascrizione non riuscita: Il modello non ha restituito alcun testo.")
        #expect(FailureText.message(for: ParolaError.engineLoadFailed("model not loaded"), bundle: it)
            == "Trascrizione non riuscita: Il modello vocale non è caricato.")
        #expect(FailureText.message(for: ParolaError.invalidLanguage("xx"), bundle: it) == "Codice lingua non valido: xx")
        #expect(FailureText.message(for: ParolaError.engineNotRegistered("whisper"), bundle: it)
            == "Questo motore vocale non è disponibile in questa build.")
        #expect(FailureText.message(for: ParolaError.policyRestricted("Model downloads are disabled by a managed policy."), bundle: it)
            == "Lo scaricamento dei modelli è disattivato da un criterio gestito.")
        #expect(FailureText.message(for: ParolaError.ioError("This entry has no audio to replace."), bundle: it)
            == "Questa trascrizione non ha audio da sostituire.")
        #expect(FailureText.message(for: ParolaError.unsupportedForEngine("Parakeet does not support translation"), bundle: it)
            == "Questo motore vocale non sa tradurre. Scegli un modello Whisper.")
        #expect(FailureText.message(for: ParolaError.modelChecksumMismatch(file: "a", expected: "b", got: "c"), bundle: it)
            == "Un file scaricato non ha superato il controllo di integrità. Scarica di nuovo il modello.")
    }

    @Test("a link failure goes through the link wording")
    func linkFailure() throws {
        let it = try bundle("it")
        let failure = LinkDownloadFailure(reason: .toolMissing)
        #expect(FailureText.message(for: ParolaError.linkDownloadFailed(failure), bundle: it)
            == AppModel.linkFailureMessage(failure, bundle: it))
    }

    @Test("delivery failures read in Italian")
    func deliveryErrors() throws {
        let it = try bundle("it")
        #expect(FailureText.message(for: DeliveryError.vaultUnavailable("Vault", "/Volumes/Note"), bundle: it)
            == "Parola non riesce a raggiungere /Volumes/Note. Scegli di nuovo la cartella nelle impostazioni di Invia a.")
        #expect(FailureText.message(for: DeliveryError.writeFailed("/Volumes/Note", "Disco pieno."), bundle: it)
            == "Parola non è riuscita a scrivere in /Volumes/Note. Disco pieno.")
        #expect(FailureText.message(for: DeliveryPayloadError.entryGone("x"), bundle: it)
            == "Questa trascrizione è stata eliminata, quindi non c'è nulla da inviare.")
        #expect(FailureText.message(for: .givenUp("Obsidian"), bundle: it) == "Parola ha smesso di provare a inviare a Obsidian.")
        #expect(FailureText.message(for: .notEnabled, bundle: it) == "Questa destinazione è disattivata.")
        #expect(FailureText.message(for: .payloadUnavailable("That transcript was deleted, so there is nothing to send."), bundle: it)
            == "Parola non è riuscita a leggere la trascrizione da inviare. Questa trascrizione è stata eliminata, quindi non c'è nulla da inviare.")
    }

    @Test("an interrupted capture reads in Italian")
    func captureInterrupted() throws {
        let it = try bundle("it")
        let error = CaptureInterrupted(url: URL(fileURLWithPath: "/tmp/take.caf"), reason: "Disco pieno")
        #expect(FailureText.message(for: error, bundle: it)
            == "La registrazione ha smesso di salvarsi a metà (Disco pieno). Quello che era già salvato si trova in /tmp/take.caf.")
    }

    @Test("AI and library failures read in Italian")
    func aiAndLibrary() throws {
        let it = try bundle("it")
        #expect(FailureText.message(for: CloudLLMError.missingAPIKey(.openAI), bundle: it) == "Nessuna chiave API configurata per OpenAI.")
        #expect(FailureText.message(for: CloudLLMError.requestFailed(provider: .groq, status: 429, body: ""), bundle: it)
            == "Richiesta a Groq non riuscita (HTTP 429).")
        #expect(FailureText.message(for: CloudLLMError.disabledByPolicy, bundle: it) == "I modelli cloud sono disattivati dalla tua organizzazione.")
        #expect(FailureText.message(for: CloudLLMError.tokenBudgetExceeded(provider: .anthropic, used: 9, limit: 5), bundle: it)
            == "La trascrizione è troppo lunga per Anthropic (9 token, limite 5).")
        #expect(FailureText.message(for: LanguageModelFactory.Failure.notAvailable("Apple Intelligence isn't available right now."), bundle: it)
            == "Apple Intelligence non è disponibile al momento.")
        #expect(FailureText.message(for: SummaryService.FailureReason.modelError("Cloud LLMs are disabled by your organization."), bundle: it)
            == "Riepilogo non riuscito: I modelli cloud sono disattivati dalla tua organizzazione.")
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
            DeliveryError.vaultUnavailable("Vault", ""),
            DeliveryError.writeFailed("/tmp/x", "No space."),
            DeliveryPayloadError.entryGone("x"),
            CloudLLMError.disabledByPolicy,
            CloudLLMError.malformedResponse(provider: .custom),
            SummaryService.FailureReason.modelError("boom"),
            TranscriptChatSession.FailureReason.modelError("boom"),
            LibraryStore.LibraryError.inTrash("x"),
        ]
        for error in errors {
            #expect(FailureText.message(for: error, bundle: en) == error.localizedDescription)
        }
    }

    @Test("the sentences the reason table matches still say what Core says")
    func knownReasonsTrackCore() throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return }
        let reasons: [SystemLanguageModel.Availability.UnavailableReason] = [.deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady]
        let it = try bundle("it")
        for reason in reasons {
            let text = LanguageModelFactory.unavailableMessage(for: reason)
            #expect(FailureText.reason(text, bundle: it) != text)
        }
        #endif
    }

    @Test("batch rows translate the feature-off reason")
    func batchReason() throws {
        let it = try bundle("it")
        #expect(FailureText.reason(ParolaError.featureDisabled(.batch).description, bundle: it)
            == "Disattivato in questa installazione: Trascrizione in batch.")
    }

    @Test("the library line says entry or entries")
    func libraryPlural() throws {
        let en = try bundle("en")
        let it = try bundle("it")
        #expect(AppModel.libraryUsageText(entries: 1, bytes: 0, bundle: en).hasPrefix("1 entry · "))
        #expect(AppModel.libraryUsageText(entries: 12, bytes: 0, bundle: en).hasPrefix("12 entries · "))
        #expect(AppModel.libraryUsageText(entries: 1, bytes: 0, bundle: it).hasPrefix("1 voce · "))
        #expect(AppModel.libraryUsageText(entries: 12, bytes: 0, bundle: it).hasPrefix("12 voci · "))
    }
}
