import Foundation
import ParolaCore

/// Core's failure sentences for a caption session, in the user's language, and the privacy pane each one points at.
enum CaptionFailure {
    nonisolated static func message(for text: String, appName: (String) -> String, bundle: Bundle = .main) -> String {
        switch text {
        case FixedFailureText.systemAudioNotAllowed:
            return String(
                localized: "Allow Parola in Screen & System Audio Recording to caption system audio.",
                bundle: bundle
            )
        case FixedFailureText.appAudioNotAllowed:
            return String(
                localized: "Allow Parola in System Audio Recording Only to caption one app.",
                bundle: bundle
            )
        case FixedFailureText.systemAudioStopped:
            return String(localized: "The system audio stopped.", bundle: bundle)
        default:
            break
        }
        if let name = appBundleID(in: text, before: FixedFailureText.appQuitSuffix) {
            return String(localized: "\(appName(name)) quit.", bundle: bundle)
        }
        if let name = appBundleID(in: text, before: FixedFailureText.appStoppedSendingSuffix) {
            return String(localized: "\(appName(name)) stopped sending audio.", bundle: bundle)
        }
        if let name = appBundleID(in: text, before: FixedFailureText.appNotPlayingAudioSuffix) {
            return String(localized: "\(appName(name)) isn't playing any audio. Try again once it is.", bundle: bundle)
        }
        return FailureText.reason(text, bundle: bundle)
    }

    /// A capture that ended by itself, as opposed to one that failed to start or an engine error.
    nonisolated static func isCaptureEnd(_ text: String) -> Bool {
        text == FixedFailureText.systemAudioStopped
            || appBundleID(in: text, before: FixedFailureText.appQuitSuffix) != nil
            || appBundleID(in: text, before: FixedFailureText.appStoppedSendingSuffix) != nil
    }

    /// Core puts a bundle ID in front of these suffixes, and a bundle ID has no whitespace.
    private nonisolated static func appBundleID(in text: String, before suffix: String) -> String? {
        guard text.hasSuffix(suffix) else { return nil }
        let name = String(text.dropLast(suffix.count))
        return name.isEmpty || name.contains(where: \.isWhitespace) ? nil : name
    }

    nonisolated static func permission(for text: String) -> RecordingSession.Permission? {
        switch text {
        case FixedFailureText.systemAudioNotAllowed: .screenRecording
        case FixedFailureText.appAudioNotAllowed: .systemAudioRecording
        case FixedFailureText.microphoneNotStarted, FixedFailureText.microphoneUnavailable: .microphone
        default: nil
        }
    }
}
