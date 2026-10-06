import Foundation
import ParolaCore

/// One pinned Hugging Face download within a voice pack: the repo at a 40-hex revision, the repo paths to
/// fetch, and the folder they install into.
public struct VoiceDownloadPart: Hashable, Sendable {
    public let repo: String
    public let revision: String
    public let include: [String]
    public let installDirectory: String
    public let sizeBytes: Int64

    public init(repo: String, revision: String, include: [String], installDirectory: String, sizeBytes: Int64) {
        self.repo = repo
        self.revision = revision
        self.include = include
        self.installDirectory = installDirectory
        self.sizeBytes = sizeBytes
    }
}

/// A voice a pack offers for one language, as the chooser lists it.
public struct VoiceOption: Identifiable, Hashable, Sendable {
    public enum Gender: Hashable, Sendable {
        case female
        case male
    }

    public let id: VoiceID
    public let displayName: String
    public let gender: Gender
    public let isDefault: Bool

    public init(id: VoiceID, displayName: String, gender: Gender, isDefault: Bool) {
        self.id = id
        self.displayName = displayName
        self.gender = gender
        self.isDefault = isDefault
    }
}

/// The terms a downloaded pack comes under: the licence name, the credit line it needs, and whether its
/// cards must say the voice is computer-generated.
public struct VoiceLicence: Hashable, Sendable {
    public let name: String
    public let attribution: String
    public let requiresSyntheticSpeechDisclosure: Bool

    public init(name: String, attribution: String, requiresSyntheticSpeechDisclosure: Bool) {
        self.name = name
        self.attribution = attribution
        self.requiresSyntheticSpeechDisclosure = requiresSyntheticSpeechDisclosure
    }
}

/// A set of voices installed and removed together. `voicesByLanguage` is keyed by base language code with
/// exactly one default voice per language; it is empty for the Apple pack, whose voices are found at run
/// time. A pack with no parts owns no folder and is always installed.
public struct VoicePack: Identifiable, Hashable, Sendable {
    public let id: String
    public let engine: SpeechEngineKind
    public let displayName: String
    public let sizeBytes: Int64
    public let parts: [VoiceDownloadPart]
    public let voicesByLanguage: [String: [VoiceOption]]
    public let licence: VoiceLicence?
    public let supersededInstallDirectories: [String]

    public init(
        id: String,
        engine: SpeechEngineKind,
        displayName: String,
        sizeBytes: Int64,
        parts: [VoiceDownloadPart],
        voicesByLanguage: [String: [VoiceOption]],
        licence: VoiceLicence?,
        supersededInstallDirectories: [String]
    ) {
        self.id = id
        self.engine = engine
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.parts = parts
        self.voicesByLanguage = voicesByLanguage
        self.licence = licence
        self.supersededInstallDirectories = supersededInstallDirectories
    }
}

/// Every voice pack Parola knows, and the neural voice it recommends per base language.
public enum VoiceCatalog {
    public static let packs: [VoicePack] = [apple]

    public static let recommended: [String: VoiceID] = [:]

    public static let apple = VoicePack(
        id: "apple",
        engine: .apple,
        displayName: "Apple",
        sizeBytes: 0,
        parts: [],
        voicesByLanguage: [:],
        licence: nil,
        supersededInstallDirectories: []
    )
}
