import Foundation

/// Mac audio that never came up: macOS holds the tap while it waits on the System Audio Recording consent, and the take gives up after a while.
struct SystemAudioDidNotStart: LocalizedError {
    var errorDescription: String? { Self.message() }

    static func message(bundle: Bundle = .main) -> String {
        String(
            localized: "Parola couldn't start recording system audio. Allow System Audio Recording for Parola in System Settings → Privacy & Security, then try again.",
            bundle: bundle
        )
    }
}
