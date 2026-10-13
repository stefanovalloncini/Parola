import Foundation
import ParolaCore

/// The app's wording for the failures ParolaCore throws. Core keeps its English text for the CLI and MCP.
enum FailureText {
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
            return String(localized: "The model \(name) isn't downloaded yet. Download it in Settings › Local Models.", bundle: bundle)
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
        case .audioLoadFailed(let url, _):
            return String(localized: "Parola couldn't load the audio from \(url.lastPathComponent).", bundle: bundle)
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
            return AppModel.linkFailureMessage(failure, bundle: bundle)
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
        case "The file is empty.":
            return String(localized: "The file is empty.", bundle: bundle)
        case "This entry has no audio to replace.":
            return String(localized: "This transcript has no audio to replace.", bundle: bundle)
        case "Model downloads are disabled by a managed policy.":
            return String(localized: "Model downloads are disabled by a managed policy.", bundle: bundle)
        case "History must end with a user turn.":
            return String(localized: "The conversation has to end with your message.", bundle: bundle)
        case "This device doesn't support Apple Intelligence.":
            return String(localized: "This device doesn't support Apple Intelligence.", bundle: bundle)
        case "Apple Intelligence is off. Turn it on in Settings to use this feature.":
            return String(localized: "Apple Intelligence is off. Turn it on in Settings to use this feature.", bundle: bundle)
        case "Apple Intelligence is still preparing its model. Try again in a little while.":
            return String(localized: "Apple Intelligence is still preparing its model. Try again in a little while.", bundle: bundle)
        case "Apple Intelligence isn't available right now.":
            return String(localized: "Apple Intelligence isn't available right now.", bundle: bundle)
        case "Apple Intelligence needs macOS 26 or iOS 26 or newer.":
            return String(localized: "Apple Intelligence needs macOS 26 or iOS 26 or newer.", bundle: bundle)
        case "Apple Speech does not support translation", "Parakeet does not support translation":
            return String(localized: "This speech engine can't translate. Pick a Whisper model.", bundle: bundle)
        case "model not loaded", "Parakeet model not loaded", "Apple Speech engine not loaded", "SpeakerKit unavailable":
            return String(localized: "The speech model isn't loaded.", bundle: bundle)
        case "WhisperKit returned no results", "WhisperKit returned an empty result set":
            return String(localized: "The model didn't return any text.", bundle: bundle)
        default:
            return nil
        }
    }

    private nonisolated static func patternedReason(_ text: String, bundle: Bundle) -> String? {
        if text.hasPrefix("The "), text.hasSuffix(" engine is disabled by a managed policy.") {
            let name = text.dropFirst("The ".count).dropLast(" engine is disabled by a managed policy.".count)
            return String(localized: "The \(String(name)) engine is disabled by a managed policy.", bundle: bundle)
        }
        if text.hasPrefix("Parola document version "), text.hasSuffix(" is newer than this app understands.") {
            return String(localized: "This transcript was saved by a newer version of Parola.", bundle: bundle)
        }
        return nil
    }
}
