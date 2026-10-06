import Foundation
import ParolaCore

/// The engines that can read aloud. The raw value is the log token and the stable name in saved settings.
public enum SpeechEngineKind: String, Sendable, CaseIterable, LogSafe {
    case apple
    case supertonic
    case pocket
    case qwen

    public var logToken: String { rawValue }
}

/// Logs a voice as its scheme and pack only: `apple:auto`, `apple:<quality>` (`apple` when the quality is
/// unknown, as for a voice no longer installed) or the neural pack id. An Apple identifier and a voice name
/// never reach the log, since a Personal Voice is named by its owner; a voice that didn't parse logs
/// `unrecognized`.
public struct VoiceToken: LogSafe {
    public enum AppleQuality: String, Sendable, CaseIterable {
        case premium
        case enhanced
        case `default`
        case personal

        public init(_ descriptor: VoiceDescriptor) {
            if descriptor.isPersonal {
                self = .personal
                return
            }
            switch descriptor.quality {
            case .premium: self = .premium
            case .enhanced: self = .enhanced
            case .default: self = .default
            }
        }
    }

    private static let unrecognized = "unrecognized"

    public let logToken: String

    public init(_ voice: VoiceID?, appleQuality: AppleQuality? = nil) {
        switch voice?.kind {
        case .appleAutomatic:
            logToken = "apple:auto"
        case .apple:
            logToken = appleQuality.map { "apple:\($0.rawValue)" } ?? "apple"
        case .neural(let pack, _):
            logToken = pack
        case nil:
            logToken = Self.unrecognized
        }
    }
}
