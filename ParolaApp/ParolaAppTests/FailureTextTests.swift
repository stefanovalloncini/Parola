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
            == "Il modello small non è ancora stato scaricato. Scaricalo da Impostazioni › Modelli locali.")
        #expect(FailureText.message(for: ParolaError.unknownModel("smal", suggestion: "small"), bundle: it)
            == "Modello “smal” sconosciuto. Intendevi “small”?")
        #expect(FailureText.message(for: ParolaError.featureDisabled(.batch), bundle: it)
            == "Funzione disattivata dalla tua organizzazione: Trascrizione in batch.")
        #expect(FailureText.message(for: ParolaError.fileMissing(file), bundle: it)
            == "Parola non è riuscita a trovare riunione.m4a.")
        #expect(FailureText.message(for: ParolaError.audioLoadFailed(file, underlying: "x"), bundle: it)
            == "Parola non è riuscita a caricare l'audio di riunione.m4a. x")
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
            == "La tua organizzazione ha disattivato il download dei modelli.")
        #expect(FailureText.message(for: ParolaError.ioError("This entry has no audio to replace."), bundle: it)
            == "Questa trascrizione non ha audio da sostituire.")
        #expect(FailureText.message(for: ParolaError.unsupportedForEngine("Parakeet does not support translation"), bundle: it)
            == "Questo motore non traduce. Scegli un modello Whisper.")
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

    @Test("Apple Speech caption failures read in Italian")
    func appleSpeechCaptionFailures() throws {
        let it = try bundle("it")
        let noModel = ParolaError.unsupportedForEngine(FixedFailureText.appleSpeechNoModel("sv_SE"))
        #expect(FailureText.message(for: noModel, bundle: it) == "Apple Speech non ha un modello per sv_SE.")
        #expect(FailureText.message(for: noModel) == "Apple Speech has no model for sv_SE.")
        let download = ParolaError.unsupportedForEngine(FixedFailureText.appleSpeechDownloadFailed("it_IT"))
        #expect(FailureText.message(for: download, bundle: it)
            == "Apple Speech non è riuscito a scaricare il modello per it_IT. Controlla la connessione e riprova.")
        #expect(FailureText.message(for: download) == FixedFailureText.appleSpeechDownloadFailed("it_IT"))
        #expect(FailureText.message(for: ParolaError.unsupportedForEngine(FixedFailureText.appleSpeechStoppedListening), bundle: it)
            == "Apple Speech ha smesso di ascoltare.")
        #expect(FailureText.message(for: ParolaError.unsupportedForEngine(FixedFailureText.appleSpeechCouldNotStart), bundle: it)
            == "Apple Speech non è riuscito ad avviarsi. Riprova.")
        let batch = ParolaError.unsupportedForEngine("Apple Speech has no model for it_IT: The operation couldn't be completed.")
        #expect(FailureText.message(for: batch, bundle: it) == "Apple Speech has no model for it_IT: The operation couldn't be completed.")
        let translate = ParolaError.unsupportedForEngine(FixedFailureText.cannotTranslate("Apple Speech"))
        #expect(FailureText.message(for: translate, bundle: it) == "Questo motore non traduce. Scegli un modello Whisper.")
    }

    @Test("delivery failures read in Italian")
    func deliveryErrors() throws {
        let it = try bundle("it")
        #expect(FailureText.message(for: DeliveryError.vaultUnavailable("Vault", "/Volumes/Note"), bundle: it)
            == "Parola non raggiunge /Volumes/Note. Scegli di nuovo la cartella in Impostazioni › Invia a.")
        #expect(FailureText.message(for: DeliveryError.writeFailed("/Volumes/Note", "Disco pieno."), bundle: it)
            == "Parola non è riuscita a scrivere in /Volumes/Note. Disco pieno.")
        #expect(FailureText.message(for: DeliveryPayloadError.entryGone("x"), bundle: it)
            == "Questa trascrizione è stata eliminata, quindi non c'è nulla da inviare.")
        #expect(FailureText.message(for: .givenUp("Obsidian"), bundle: it) == "Parola ha smesso di riprovare l'invio a Obsidian.")
        #expect(FailureText.message(for: .notEnabled, bundle: it) == "Questa destinazione è disattivata.")
        #expect(FailureText.message(for: .payloadUnavailable("That transcript was deleted, so there is nothing to send."), bundle: it)
            == "Parola non è riuscita a leggere la trascrizione da inviare. Questa trascrizione è stata eliminata, quindi non c'è nulla da inviare.")
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
        #expect(FailureText.message(for: CloudLLMError.requestFailed(provider: .groq, status: 429, body: ""), bundle: it)
            == "Richiesta a Groq non riuscita (HTTP 429).")
        #expect(FailureText.message(for: CloudLLMError.disabledByPolicy, bundle: it) == "La tua organizzazione ha disattivato gli LLM cloud.")
        #expect(FailureText.message(for: CloudLLMError.tokenBudgetExceeded(provider: .anthropic, used: 9, limit: 5), bundle: it)
            == "La trascrizione è troppo lunga per Anthropic (9 token, limite 5).")
        #expect(FailureText.message(for: LanguageModelFactory.Failure.notAvailable("Apple Intelligence isn't available right now."), bundle: it)
            == "Apple Intelligence non è disponibile al momento.")
        #expect(FailureText.message(for: SummaryService.FailureReason.modelError("Cloud LLMs are disabled by your organization."), bundle: it)
            == "Riepilogo non riuscito: La tua organizzazione ha disattivato gli LLM cloud.")
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

    @Test("Core's fixed sentences are matched through its constants")
    func fixedSentences() throws {
        let it = try bundle("it")
        let constants = [
            FixedFailureText.modelDownloadsDisabled, FixedFailureText.englishOnly, FixedFailureText.fileIsEmpty,
            FixedFailureText.noAudioToReplace, FixedFailureText.historyMustEndWithUserTurn, FixedFailureText.engineModelNotLoaded,
            FixedFailureText.speakerModelUnavailable, FixedFailureText.noResults, FixedFailureText.emptyResultSet,
            FixedFailureText.microphoneUnavailable, FixedFailureText.microphoneNotStarted, FixedFailureText.appleIntelligenceUnsupportedDevice,
            FixedFailureText.appleIntelligenceOff, FixedFailureText.appleIntelligencePreparing,
            FixedFailureText.appleIntelligenceUnavailable, FixedFailureText.appleIntelligenceNeedsNewerOS,
            FixedFailureText.engineDisabled("Parakeet"), FixedFailureText.cannotTranslate("Parakeet"),
            FixedFailureText.cannotLabelSpeakers("Parakeet"), FixedFailureText.documentTooNew(version: 9),
        ]
        for text in constants { #expect(FailureText.reason(text, bundle: it) != text, "\(text)") }
    }

    @Test("the engine checks a transcription session makes are translated")
    func sessionSentences() throws {
        let it = try bundle("it")
        #expect(FailureText.message(for: ParolaError.unsupportedForEngine(FixedFailureText.cannotTranslate("Parakeet")), bundle: it)
            == "Questo motore non traduce. Scegli un modello Whisper.")
        #expect(FailureText.message(for: ParolaError.unsupportedForEngine(FixedFailureText.cannotLabelSpeakers("Parakeet")), bundle: it)
            == "Parakeet non sa distinguere gli speaker.")
        #expect(FailureText.message(for: ParolaError.policyRestricted(FixedFailureText.englishOnly), bundle: it)
            == "La tua organizzazione limita la trascrizione all'inglese.")
        #expect(FailureText.message(for: ParolaError.policyRestricted(FixedFailureText.engineDisabled("Parakeet")), bundle: it)
            == "La tua organizzazione ha disattivato il motore Parakeet.")
        #expect(FailureText.message(for: ParolaError.captureUnavailable(FixedFailureText.microphoneUnavailable), bundle: it)
            == "Registrazione audio non disponibile: Il microfono non è disponibile. Controlla che Parola possa usarlo in Impostazioni di Sistema → Privacy e sicurezza → Microfono.")
        #expect(FailureText.reason(FixedFailureText.microphoneNotStarted, bundle: it)
            == "Il microfono non è disponibile. Controlla che Parola possa usarlo in Impostazioni di Sistema → Privacy e sicurezza → Microfono.")
    }

    @Test("a capture failure reaching a live take is translated through its reason")
    func capturePrefix() throws {
        let it = try bundle("it")
        #expect(FailureText.reason(ParolaError.captureUnavailable(FixedFailureText.microphoneUnavailable).description, bundle: it)
            == "Registrazione audio non disponibile: Il microfono non è disponibile. Controlla che Parola possa usarlo in Impostazioni di Sistema → Privacy e sicurezza → Microfono.")
    }

    @Test("a missing video reads as a missing file, and other audio failures keep their reason")
    func audioLoad() throws {
        let it = try bundle("it")
        let url = URL(fileURLWithPath: "/tmp/clip.mp4")
        #expect(FailureText.message(for: ParolaError.audioLoadFailed(url, underlying: FixedFailureText.videoMissing), bundle: it)
            == "Parola non è riuscita a trovare clip.mp4.")
        #expect(FailureText.message(for: ParolaError.audioLoadFailed(url, underlying: FixedFailureText.fileIsEmpty), bundle: it)
            == "Parola non è riuscita a caricare l'audio di clip.mp4. Il file è vuoto.")
    }

    @Test("a delete failure drops Core's own lead-in, and a failed download isn't framed twice")
    func modelFailures() throws {
        let it = try bundle("it")
        #expect(FailureText.message(for: ParolaError.ioError("Failed to delete small: Operation not permitted"), bundle: it)
            == "Operation not permitted")
        let failed = ParolaError.modelDownloadFailed("small", underlying: "boom")
        #expect(AppModel.downloadFailureMessage(for: failed, bundle: it) == "Impossibile scaricare il modello small: boom")
        #expect(AppModel.downloadFailureMessage(for: Unlisted(), bundle: it) == "Download non riuscito: Something only the system knows.")
    }

    @Test("a batch job's failure is worded from its error")
    func batchError() throws {
        let it = try bundle("it")
        let event = BatchEvent.failed(jobID: UUID(), reason: "x", error: ParolaError.fileMissing(URL(fileURLWithPath: "/tmp/a.m4a")))
        guard case .failed(_, _, let error?) = event else { Issue.record("no error"); return }
        #expect(FailureText.message(for: error, bundle: it) == "Parola non è riuscita a trovare a.m4a.")
    }

    @Test("what the dictation recorder throws is already worded")
    func presented() throws {
        let error = FailureText.presented(ParolaError.invalidLanguage("xx"))
        #expect(error.localizedDescription == FailureText.message(for: ParolaError.invalidLanguage("xx")))
        #expect(FailureText.presented(CancellationError()) is CancellationError)
    }

    @Test("Apple Intelligence reasons shown in the app are translated")
    func aiReason() throws {
        let it = try bundle("it")
        #expect(FailureText.reason("Apple Intelligence is off. Turn it on in Settings to use this feature.", bundle: it)
            == "Apple Intelligence è disattivata. Attivala in Impostazioni di Sistema per usare questa funzione.")
    }

    @Test("batch rows translate the feature-off reason")
    func batchReason() throws {
        let it = try bundle("it")
        #expect(FailureText.reason(ParolaError.featureDisabled(.batch).description, bundle: it)
            == "Funzione disattivata dalla tua organizzazione: Trascrizione in batch.")
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
