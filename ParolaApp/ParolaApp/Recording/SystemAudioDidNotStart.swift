import Foundation

/// Mac audio that never came up: macOS holds the tap while it waits on the System Audio Recording consent, and the take gives up after a while.
struct SystemAudioDidNotStart: LocalizedError {
    var errorDescription: String? { Self.message() }

    static func message(bundle: Bundle = .main) -> String {
        String(
            localized: "Parola couldn't start recording system audio. Open System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only and allow Parola, then try again.",
            bundle: bundle
        )
    }
}
