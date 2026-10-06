import Foundation

/// An installed Apple speech voice, described without any AVFoundation dependency so the ranking logic can be tested with fixtures.
public struct VoiceDescriptor: Hashable, Sendable {
    public enum Quality: Hashable, Sendable {
        case `default`
        case enhanced
        case premium
    }

    public enum Family: Hashable, Sendable {
        case standard
        case eloquence
        case macinTalk
    }

    public var identifier: String
    public var name: String
    public var language: String
    public var quality: Quality
    public var isNovelty: Bool
    public var isPersonal: Bool
    public var family: Family

    public init(
        identifier: String,
        name: String,
        language: String,
        quality: Quality,
        isNovelty: Bool,
        isPersonal: Bool,
        family: Family
    ) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
        self.isNovelty = isNovelty
        self.isPersonal = isPersonal
        self.family = family
    }
}
