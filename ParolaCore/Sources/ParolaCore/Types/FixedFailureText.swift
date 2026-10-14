import Foundation

/// Failure sentences that front ends recognise and present in their own language. Changing one changes what they match.
public enum FixedFailureText {
    public static let modelDownloadsDisabled = "Model downloads are disabled by a managed policy."
    public static let englishOnly = "Transcription is restricted to English by a managed policy."
    public static let fileIsEmpty = "The file is empty."
    public static let noAudioToReplace = "This entry has no audio to replace."
    public static let historyMustEndWithUserTurn = "History must end with a user turn."
    public static let engineModelNotLoaded = "model not loaded"
    public static let speakerModelUnavailable = "SpeakerKit unavailable"
    public static let noResults = "WhisperKit returned no results"
    public static let emptyResultSet = "WhisperKit returned an empty result set"
    public static let microphoneUnavailable = "microphone not available — input format invalid (mic permission?)"
    public static let microphoneNotStarted = "Couldn't start the microphone. Check Microphone access in System Settings › Privacy & Security › Microphone."
    public static let systemAudioNotAllowed = "Couldn't capture system audio. Allow Parola in System Settings › Privacy & Security › Screen & System Audio Recording."
    public static let appAudioNotAllowed = "Couldn't capture that app's audio. Allow Parola in System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording Only."
    public static let videoMissing = "video file does not exist"
    public static let appleIntelligenceUnsupportedDevice = "This device doesn't support Apple Intelligence."
    public static let appleIntelligenceOff = "Apple Intelligence is off. Turn it on in Settings to use this feature."
    public static let appleIntelligencePreparing = "Apple Intelligence is still preparing its model. Try again in a little while."
    public static let appleIntelligenceUnavailable = "Apple Intelligence isn't available right now."
    public static let appleIntelligenceNeedsNewerOS = "Apple Intelligence needs macOS 26 or iOS 26 or newer."

    public static let appNotPlayingAudioSuffix = " isn't playing any audio. Try again once it is."

    public static func appNotPlayingAudio(_ app: String) -> String {
        app + appNotPlayingAudioSuffix
    }

    public static let systemAudioStopped = "The system audio stopped."
    public static let appQuitSuffix = " quit."

    public static func appQuit(_ app: String) -> String {
        app + appQuitSuffix
    }

    public static let appStoppedSendingSuffix = " stopped sending audio."

    public static func appStoppedSending(_ app: String) -> String {
        app + appStoppedSendingSuffix
    }

    public static func engineDisabled(_ engineName: String) -> String {
        "The \(engineName) engine is disabled by a managed policy."
    }

    public static func cannotTranslate(_ engineName: String) -> String {
        "\(engineName) does not support translation."
    }

    public static func cannotLabelSpeakers(_ engineName: String) -> String {
        "\(engineName) does not support speaker labels."
    }

    public static func documentTooNew(version: Int) -> String {
        "Parola document version \(version) is newer than this app understands."
    }
}
