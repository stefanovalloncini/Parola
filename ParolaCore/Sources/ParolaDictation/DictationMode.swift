import Foundation

public enum DictationMode: String, CaseIterable, Sendable, Codable {
    /// Hold the key to listen; release to transcribe.
    case pushToTalk
    /// Tap the key to start; tap again to stop and transcribe.
    case toggle
    /// Tap (under 300 ms) acts as toggle; longer hold acts as push-to-talk.
    case hybrid

    public var displayName: String {
        switch self {
        case .pushToTalk: return "Push to talk"
        case .toggle:     return "Toggle"
        case .hybrid:     return "Hybrid"
        }
    }

    public var description: String {
        switch self {
        case .pushToTalk: return "Hold the key to listen, release to insert."
        case .toggle:     return "Tap once to start, tap again to insert."
        case .hybrid:     return "Tap to toggle, hold for push-to-talk."
        }
    }
}
