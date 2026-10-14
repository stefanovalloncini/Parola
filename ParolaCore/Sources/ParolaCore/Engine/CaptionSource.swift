import Foundation

/// What Live Captions listen to.
public enum CaptionSource: Sendable, Hashable, Codable {
    case microphone(deviceUID: String?)
    case systemAudio
    case app(bundleID: String)

    private static let microphoneSetting = "microphone"
    private static let systemAudioSetting = "systemAudio"
    private static let appPrefix = "app:"

    /// The string the app persists: the input device is a separate setting, so a microphone source carries none.
    public var setting: String {
        switch self {
        case .microphone: Self.microphoneSetting
        case .systemAudio: Self.systemAudioSetting
        case .app(let bundleID): Self.appPrefix + bundleID
        }
    }

    /// Anything unrecognised reads as the microphone.
    public init(setting: String?, deviceUID: String? = nil) {
        switch setting {
        case Self.systemAudioSetting:
            self = .systemAudio
        case let value? where value.hasPrefix(Self.appPrefix) && value.count > Self.appPrefix.count:
            self = .app(bundleID: String(value.dropFirst(Self.appPrefix.count)))
        default:
            self = .microphone(deviceUID: deviceUID)
        }
    }

    public var deviceUID: String? {
        if case .microphone(let uid) = self { uid } else { nil }
    }

    public var isMicrophone: Bool {
        if case .microphone = self { true } else { false }
    }
}
