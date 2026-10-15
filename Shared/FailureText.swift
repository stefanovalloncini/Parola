import Foundation
import ParolaCore

/// A failure already worded for the person, for code in ParolaCore that shows `localizedDescription` as it is.
struct PresentedFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The app's wording for the failures ParolaCore throws. Core keeps its English text for the CLI and MCP.
enum FailureText {
    nonisolated static func presented(_ error: any Error) -> any Error {
        if error is CancellationError || error is PresentedFailure { return error }
        return PresentedFailure(message: message(for: error))
    }

    nonisolated static func message(for error: any Error, bundle: Bundle = .main) -> String {
        switch error {
        case let error as ParolaError: return parola(error, bundle: bundle)
        case let error as DeliveryError: return delivery(error, bundle: bundle)
        case let error as DeliveryPayloadError: return payload(error, bundle: bundle)
        case let error as CaptureInterrupted:
            return String(
                localized: "The recording stopped saving partway (\(reason(error.reason, bundle: bundle))). What was saved is kept at \(error.url.path).",
                bundle: bundle
            )
        case let error as CloudLLMError: return cloud(error, bundle: bundle)
        case let error as LanguageModelFactory.Failure:
            switch error {
            case .notAvailable(let text): return reason(text, bundle: bundle)
            }
        case let error as SummaryService.FailureReason:
            switch error {
            case .modelError(let text): return String(localized: "Summary failed: \(reason(text, bundle: bundle))", bundle: bundle)
            }
        case let error as TranscriptChatSession.FailureReason:
            switch error {
            case .modelError(let text): return String(localized: "Chat failed: \(reason(text, bundle: bundle))", bundle: bundle)
            }
        case let error as LibraryStore.LibraryError: return library(error, bundle: bundle)
        case let error as CardMetadataService.Failure: return cardMetadata(error, bundle: bundle)
        default: return error.localizedDescription
        }
    }

    nonisolated static func message(for reason: DeliverySkipReason, bundle: Bundle = .main) -> String {
        switch reason {
        case .unknownDestination:
            return String(localized: "That destination is no longer in Send To settings.", bundle: bundle)
        case .notEnabled:
            return String(localized: "That destination is switched off.", bundle: bundle)
        case .unsupportedKind(let kind):
            return String(localized: "This version of Parola can't send to a \(kind) destination.", bundle: bundle)
        case .payloadUnavailable(let text):
            return String(localized: "Parola couldn't read the transcript to send. \(Self.reason(text, bundle: bundle))", bundle: bundle)
        case .givenUp(let name):
            return String(localized: "Parola stopped trying to send to \(name).", bundle: bundle)
        case .alreadySending(let name):
            return String(localized: "Parola is already sending that transcript to \(name).", bundle: bundle)
        }
    }

    /// A reason Core already folded into a string: the fixed sentences it can carry are translated, anything else passes through.
    nonisolated static func reason(_ text: String, bundle: Bundle = .main) -> String {
        if let fixed = fixedReason(text, bundle: bundle) { return fixed }
        if let patterned = patternedReason(text, bundle: bundle) { return patterned }
        return text
    }

    // MARK: - ParolaError

    private nonisolated static func parola(_ error: ParolaError, bundle: Bundle) -> String {
        switch error {
        case .modelNotFound(let name):
            #if os(macOS)
            return String(localized: "The model \(name) isn't downloaded yet. Download it in Settings › Local Models.", bundle: bundle)
            #else
            return String(localized: "The model \(name) isn't downloaded yet. Download it in Settings › Models on device.", bundle: bundle)
            #endif
        case .unknownModel(let name, let suggestion):
            guard let suggestion else { return String(localized: "Unknown model “\(name)”.", bundle: bundle) }
            return String(localized: "Unknown model “\(name)”. Did you mean “\(suggestion)”?", bundle: bundle)
        case .policyRestricted(let detail):
            return reason(detail, bundle: bundle)
        case .featureDisabled(let feature):
            return String(localized: "\(featureName(feature, bundle: bundle)) is disabled in this deployment.", bundle: bundle)
        case .modelDownloadFailed(let name, let underlying):
            return String(localized: "Failed to download model \(name): \(underlying)", bundle: bundle)
        case .modelChecksumMismatch:
            return String(localized: "A downloaded file failed its integrity check. Download the model again.", bundle: bundle)
        case .audioLoadFailed(let url, let underlying):
            if underlying == FixedFailureText.videoMissing { return parola(.fileMissing(url), bundle: bundle) }
            return String(localized: "Parola couldn't load the audio from \(url.lastPathComponent). \(reason(underlying, bundle: bundle))", bundle: bundle)
        case .fileMissing(let url):
            return String(localized: "Parola couldn't find \(url.lastPathComponent).", bundle: bundle)
        case .transcriptionFailed(let text), .engineLoadFailed(let text):
            return String(localized: "Transcription failed: \(reason(text, bundle: bundle))", bundle: bundle)
        case .unreadableFile(let name, let text):
            let lead = String(localized: "Parola couldn't read \(name).", bundle: bundle)
            guard let text else { return lead }
            return lead + " " + reason(text, bundle: bundle)
        case .fileReadTimedOut(let name):
            return String(localized: "Parola couldn't read \(name) in time.", bundle: bundle)
        case .unsupportedAudioFormat(let detail):
            return String(localized: "Unsupported audio format: \(detail)", bundle: bundle)
        case .captureUnavailable(let text):
            return String(localized: "Audio capture unavailable: \(reason(text, bundle: bundle))", bundle: bundle)
        case .linkDownloadFailed(let failure):
            #if os(macOS)
            return AppModel.linkFailureMessage(failure, bundle: bundle)
            #else
            return error.localizedDescription
            #endif
        case .invalidLanguage(let code):
            return String(localized: "Invalid language code: \(code)", bundle: bundle)
        case .ioError(let text), .unsupportedForEngine(let text):
            return reason(text, bundle: bundle)
        case .engineNotRegistered:
            return String(localized: "This speech engine isn't available in this build.", bundle: bundle)
        }
    }

    private nonisolated static func featureName(_ feature: ParolaFeature, bundle: Bundle) -> String {
        switch feature {
        case .dictation: return String(localized: "Dictation", bundle: bundle)
        case .meetings: return String(localized: "Meeting recording", bundle: bundle)
        case .micRecording: return String(localized: "Microphone recording", bundle: bundle)
        case .liveCaptions: return String(localized: "Live Captions", bundle: bundle)
        case .youtube: return String(localized: "YouTube ingestion", bundle: bundle)
        case .batch: return String(localized: "Batch transcription", bundle: bundle)
        case .ai: return String(localized: "AI", bundle: bundle)
        case .automation: return String(localized: "Automation", bundle: bundle)
        case .watchedFolders: return String(localized: "Watched folders", bundle: bundle)
        case .destinations: return String(localized: "Send To", bundle: bundle)
        }
    }

    // MARK: - Delivery

    private nonisolated static func delivery(_ error: DeliveryError, bundle: Bundle) -> String {
        switch error {
        case .vaultUnavailable(let name, let path):
            let place = path.isEmpty ? name : path
            return String(localized: "Parola couldn't reach \(place). Pick the folder again in Send To settings.", bundle: bundle)
        case .writeFailed(let path, let text):
            return String(localized: "Parola couldn't write to \(path). \(text)", bundle: bundle)
        case .httpStatus(let name, let status, let detail):
            return detail.isEmpty
                ? String(localized: "\(name) answered HTTP \(status).", bundle: bundle)
                : String(localized: "\(name) answered HTTP \(status). \(detail)", bundle: bundle)
        case .networkFailed(let host, let text):
            return String(localized: "Parola couldn't reach \(host). \(text)", bundle: bundle)
        case .missingSecret(let name):
            return String(localized: "\(name) has no saved key. Enter it again in Send To settings.", bundle: bundle)
        case .invalidSetup(let name, let text):
            return String(localized: "\(name) isn't set up correctly. \(text)", bundle: bundle)
        case .partialDelivery(let name, let sent, let total, let text):
            return String(localized: "\(name) got \(sent) of \(total) blocks before it failed, and the page stays there. \(text)", bundle: bundle)
        }
    }

    private nonisolated static func payload(_ error: DeliveryPayloadError, bundle: Bundle) -> String {
        switch error {
        case .entryGone: return String(localized: "That transcript was deleted, so there is nothing to send.", bundle: bundle)
        }
    }

    // MARK: - AI

    private nonisolated static func cloud(_ error: CloudLLMError, bundle: Bundle) -> String {
        switch error {
        case .missingAPIKey(let id):
            return String(localized: "No API key configured for \(providerName(id)).", bundle: bundle)
        case .requestFailed(let id, let status, _):
            return String(localized: "\(providerName(id)) request failed (HTTP \(status)).", bundle: bundle)
        case .streamError(let id, let text):
            return String(localized: "\(providerName(id)) failed mid-response: \(text)", bundle: bundle)
        case .malformedResponse(let id):
            return String(localized: "\(providerName(id)) returned a malformed response.", bundle: bundle)
        case .unsupportedProvider(let id):
            return String(localized: "Unsupported cloud provider: \(providerName(id)).", bundle: bundle)
        case .disabledByPolicy:
            return String(localized: "Cloud LLMs are disabled by your organization.", bundle: bundle)
        case .tokenBudgetExceeded(let id, let used, let limit):
            return String(localized: "This transcript is too long for \(providerName(id)) (\(used) tokens, limit \(limit)).", bundle: bundle)
        }
    }

    private nonisolated static func providerName(_ id: CloudLLMProviderID) -> String {
        CloudLLMProviderInfo.info(for: id)?.displayName ?? id.description
    }

    private nonisolated static func cardMetadata(_ error: CardMetadataService.Failure, bundle: Bundle) -> String {
        switch error {
        case .tooShort: return String(localized: "This transcript is too short for a title and summary.", bundle: bundle)
        case .featureDisabled: return parola(.featureDisabled(.ai), bundle: bundle)
        }
    }

    // MARK: - Library

    private nonisolated static func library(_ error: LibraryStore.LibraryError, bundle: Bundle) -> String {
        switch error {
        case .notFound: return String(localized: "That transcript isn't in your library.", bundle: bundle)
        case .inTrash: return String(localized: "This transcript is in Recently Deleted. Restore it to open it.", bundle: bundle)
        }
    }

    // MARK: - Reasons

    private nonisolated static func fixedReason(_ text: String, bundle: Bundle) -> String? {
        if text == ParolaError.featureDisabled(.batch).description { return parola(.featureDisabled(.batch), bundle: bundle) }
        if text == ParolaError.featureDisabled(.ai).description { return parola(.featureDisabled(.ai), bundle: bundle) }
        if text == DeliveryPayloadError.entryGone("").errorDescription { return payload(.entryGone(""), bundle: bundle) }
        if text == LibraryStore.LibraryError.inTrash("").errorDescription { return library(.inTrash(""), bundle: bundle) }
        if text == CloudLLMError.disabledByPolicy.errorDescription { return cloud(.disabledByPolicy, bundle: bundle) }
        switch text {
        case FixedFailureText.fileIsEmpty:
            return String(localized: "The file is empty.", bundle: bundle)
        case FixedFailureText.noAudioToReplace:
            return String(localized: "This transcript has no audio to replace.", bundle: bundle)
        case FixedFailureText.modelDownloadsDisabled:
            return String(localized: "Model downloads are disabled by a managed policy.", bundle: bundle)
        case FixedFailureText.englishOnly:
            return String(localized: "Transcription is restricted to English by a managed policy.", bundle: bundle)
        case FixedFailureText.historyMustEndWithUserTurn:
            return String(localized: "The conversation has to end with your message.", bundle: bundle)
        case FixedFailureText.appleIntelligenceUnsupportedDevice:
            return String(localized: "This device doesn't support Apple Intelligence.", bundle: bundle)
        case FixedFailureText.appleIntelligenceOff:
            return String(localized: "Apple Intelligence is off. Turn it on in Settings to use this feature.", bundle: bundle)
        case FixedFailureText.appleIntelligencePreparing:
            return String(localized: "Apple Intelligence is still preparing its model. Try again in a little while.", bundle: bundle)
        case FixedFailureText.appleIntelligenceUnavailable:
            return String(localized: "Apple Intelligence isn't available right now.", bundle: bundle)
        case FixedFailureText.appleIntelligenceNeedsNewerOS:
            return String(localized: "Apple Intelligence needs macOS 26 or iOS 26 or newer.", bundle: bundle)
        case FixedFailureText.microphoneUnavailable, FixedFailureText.microphoneNotStarted:
            #if os(macOS)
            return String(localized: "The microphone isn't available. Check that Parola can use it in System Settings → Privacy & Security → Microphone.", bundle: bundle)
            #else
            return String(localized: "The microphone isn't available. Check that Parola can use it in Settings → Privacy & Security → Microphone.", bundle: bundle)
            #endif
        case FixedFailureText.speakerModelUnavailable:
            return String(localized: "The speaker labelling model isn't available.", bundle: bundle)
        case FixedFailureText.appleSpeechStoppedListening:
            return String(localized: "Apple Speech stopped listening.", bundle: bundle)
        case FixedFailureText.appleSpeechCouldNotStart:
            return String(localized: "Apple Speech couldn't start. Try again.", bundle: bundle)
        case "Apple Speech does not support translation":
            return String(localized: "This engine can't translate. Pick a Whisper model.", bundle: bundle)
        case FixedFailureText.engineModelNotLoaded, "Parakeet model not loaded", "Apple Speech engine not loaded":
            return String(localized: "The speech model isn't loaded.", bundle: bundle)
        case FixedFailureText.noResults, FixedFailureText.emptyResultSet:
            return String(localized: "The model didn't return any text.", bundle: bundle)
        default:
            return nil
        }
    }

    private nonisolated static func patternedReason(_ text: String, bundle: Bundle) -> String? {
        let policy = " engine is disabled by a managed policy."
        if text.hasPrefix("The "), text.hasSuffix(policy) {
            let name = String(text.dropFirst("The ".count).dropLast(policy.count))
            return String(localized: "The \(name) engine is disabled by a managed policy.", bundle: bundle)
        }
        for ending in [" does not support translation.", " does not support translation"] where text.hasSuffix(ending) {
            return String(localized: "This engine can't translate. Pick a Whisper model.", bundle: bundle)
        }
        if text.hasPrefix(FixedFailureText.appleSpeechNoModelPrefix), text.hasSuffix("."), !text.contains(":") {
            let locale = String(text.dropFirst(FixedFailureText.appleSpeechNoModelPrefix.count).dropLast())
            return String(localized: "Apple Speech has no model for \(locale).", bundle: bundle)
        }
        if text.hasPrefix(FixedFailureText.appleSpeechDownloadFailedPrefix),
           text.hasSuffix(FixedFailureText.appleSpeechDownloadFailedSuffix) {
            let locale = String(text.dropFirst(FixedFailureText.appleSpeechDownloadFailedPrefix.count)
                .dropLast(FixedFailureText.appleSpeechDownloadFailedSuffix.count))
            return String(localized: "Apple Speech couldn't download its model for \(locale). Check your connection and try again.", bundle: bundle)
        }
        let labels = " does not support speaker labels."
        if text.hasSuffix(labels) {
            return String(localized: "\(String(text.dropLast(labels.count))) can't label speakers.", bundle: bundle)
        }
        if text.hasPrefix("Parola document version "), text.hasSuffix(" is newer than this app understands.") {
            return String(localized: "This transcript was saved by a newer version of Parola.", bundle: bundle)
        }
        if text.hasPrefix("Failed to delete "), let colon = text.range(of: ": ") {
            return reason(String(text[colon.upperBound...]), bundle: bundle)
        }
        let capture = "Audio capture unavailable: "
        if text.hasPrefix(capture) {
            return String(localized: "Audio capture unavailable: \(reason(String(text.dropFirst(capture.count)), bundle: bundle))", bundle: bundle)
        }
        let transcription = "Transcription failed: "
        if text.hasPrefix(transcription) {
            return String(localized: "Transcription failed: \(reason(String(text.dropFirst(transcription.count)), bundle: bundle))", bundle: bundle)
        }
        return nil
    }
}
