import Foundation

public enum ParolaError: LocalizedError, CustomStringConvertible, Sendable {
    case modelNotFound(String)
    case unknownModel(String, suggestion: String?)
    case policyRestricted(String)
    case featureDisabled(ParolaFeature)
    case modelDownloadFailed(String, underlying: String)
    case modelChecksumMismatch(file: String, expected: String, got: String)
    case audioLoadFailed(URL, underlying: String)
    case transcriptionFailed(String)
    case unsupportedAudioFormat(String)
    case captureUnavailable(String)
    case invalidLanguage(String)
    case ioError(String)
    case engineNotRegistered(String)
    case unsupportedForEngine(String)

    public var description: String {
        switch self {
        case .modelNotFound(let name):
            return "Model not found: \(name). Run `parola models download \(name)` first."
        case .unknownModel(let name, let suggestion):
            var text = "Unknown model \"\(name)\"."
            if let suggestion {
                text += " Did you mean \"\(suggestion)\"?"
            }
            return text
        case .policyRestricted(let detail):
            return detail
        case .featureDisabled(let feature):
            return "\(feature.displayName) is disabled in this deployment."
        case .modelDownloadFailed(let name, let underlying):
            return "Failed to download model \(name): \(underlying)"
        case .modelChecksumMismatch(let file, let expected, let got):
            return "Checksum mismatch for \(file): expected \(expected), got \(got)"
        case .audioLoadFailed(let url, let underlying):
            return "Failed to load audio at \(url.path): \(underlying)"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .unsupportedAudioFormat(let detail):
            return "Unsupported audio format: \(detail)"
        case .captureUnavailable(let reason):
            return "Audio capture unavailable: \(reason)"
        case .invalidLanguage(let code):
            return "Invalid language code: \(code)"
        case .ioError(let reason):
            return reason
        case .engineNotRegistered(let id):
            return "Engine \"\(id)\" is not registered. Call ParolaCoreBootstrap.registerBuiltInEngines() before transcribing."
        case .unsupportedForEngine(let detail):
            return detail
        }
    }

    public var errorDescription: String? { description }

    /// Sanitized rendering for diagnostics. Drops every associated value that
    /// could carry a path, a file name, or a laundered `localizedDescription`;
    /// echoes only values that pass an allowlist check.
    public var logKind: String {
        switch self {
        case .modelNotFound(let name):
            return "ParolaError.modelNotFound(\(LogAllowlist.modelID(name)))"
        case .unknownModel(let name, _):
            return "ParolaError.unknownModel(\(LogAllowlist.modelID(name)))"
        case .policyRestricted:
            return "ParolaError.policyRestricted"
        case .featureDisabled(let feature):
            return "ParolaError.featureDisabled(\(feature.rawValue))"
        case .modelDownloadFailed(let name, _):
            return "ParolaError.modelDownloadFailed(\(LogAllowlist.modelID(name)))"
        case .modelChecksumMismatch:
            return "ParolaError.modelChecksumMismatch"
        case .audioLoadFailed:
            return "ParolaError.audioLoadFailed"
        case .transcriptionFailed:
            return "ParolaError.transcriptionFailed"
        case .unsupportedAudioFormat:
            return "ParolaError.unsupportedAudioFormat"
        case .captureUnavailable:
            return "ParolaError.captureUnavailable"
        case .invalidLanguage(let code):
            return "ParolaError.invalidLanguage(\(LogAllowlist.languageCode(code)))"
        case .ioError:
            return "ParolaError.ioError"
        case .engineNotRegistered(let id):
            return "ParolaError.engineNotRegistered(\(LogAllowlist.engineID(id)))"
        case .unsupportedForEngine:
            return "ParolaError.unsupportedForEngine"
        }
    }
}

/// URLSession surfaces a cancelled Swift task as `URLError(.cancelled)`, not `CancellationError`,
/// so download paths need both checks to report a user cancel as a cancel instead of a failure.
func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    return (error as? URLError)?.code == .cancelled
}
