import Foundation

/// The voice a language is read with, saved as a string that must decode unchanged across app updates: `apple:auto`, `apple:<AVSpeechSynthesisVoice.identifier>` or `<packID>/<voice>`.
public struct VoiceID: Hashable, Codable, Sendable, RawRepresentable {
    public enum Kind: Hashable, Sendable {
        case appleAutomatic
        case apple(identifier: String)
        case neural(pack: String, voice: String)
    }

    public let rawValue: String

    public init?(rawValue: String) {
        guard VoiceID.kind(forRawValue: rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    private init(validRawValue: String) {
        self.rawValue = validRawValue
    }

    public static let appleAutomatic = VoiceID(validRawValue: "apple:auto")

    public static func apple(identifier: String) -> VoiceID? {
        guard isValidAppleIdentifier(identifier) else { return nil }
        return VoiceID(validRawValue: "apple:\(identifier)")
    }

    public static func neural(pack: String, voice: String) -> VoiceID? {
        guard isValidPack(pack), isValidVoice(voice) else { return nil }
        return VoiceID(validRawValue: "\(pack)/\(voice)")
    }

    public var kind: Kind {
        guard let kind = VoiceID.kind(forRawValue: rawValue) else {
            preconditionFailure("VoiceID held an invalid rawValue: \(rawValue)")
        }
        return kind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = VoiceID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid VoiceID: \(raw)")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func kind(forRawValue rawValue: String) -> Kind? {
        if rawValue == "apple:auto" {
            return .appleAutomatic
        }
        if rawValue.hasPrefix("apple:") {
            let identifier = String(rawValue.dropFirst("apple:".count))
            guard isValidAppleIdentifier(identifier) else { return nil }
            return .apple(identifier: identifier)
        }
        guard let slash = rawValue.firstIndex(of: "/") else { return nil }
        let pack = String(rawValue[rawValue.startIndex..<slash])
        let voice = String(rawValue[rawValue.index(after: slash)...])
        guard isValidPack(pack), isValidVoice(voice) else { return nil }
        return .neural(pack: pack, voice: voice)
    }

    private static func isValidAppleIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier.trimmingCharacters(in: .whitespaces) == identifier else {
            return false
        }
        return identifier.lowercased() != "auto"
    }

    private static func isValidPack(_ pack: String) -> Bool {
        pack.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil
    }

    private static func isValidVoice(_ voice: String) -> Bool {
        !voice.isEmpty && !voice.contains("/")
    }
}
