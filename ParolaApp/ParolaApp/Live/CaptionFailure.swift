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
        default:
            break
        }
        let suffix = FixedFailureText.appNotPlayingAudioSuffix
        if text.hasSuffix(suffix) {
            let name = appName(String(text.dropLast(suffix.count)))
            return String(localized: "\(name) isn't playing any audio. Try again once it is.", bundle: bundle)
        }
        return FailureText.reason(text, bundle: bundle)
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
