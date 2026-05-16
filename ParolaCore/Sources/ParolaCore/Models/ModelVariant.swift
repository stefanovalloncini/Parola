import Foundation

public enum ModelCategory: String, CaseIterable, Sendable, Hashable, Codable {
    case recommended
    case fastest
    case mostAccurate
    case compact
    case specialized

    public var displayName: String {
        switch self {
        case .recommended: return "Recommended"
        case .fastest: return "Fastest"
        case .mostAccurate: return "Highest accuracy"
        case .compact: return "Smallest"
        case .specialized: return "Specialized"
        }
    }

    public var sortOrder: Int {
        switch self {
        case .recommended: return 0
        case .fastest: return 1
        case .mostAccurate: return 2
        case .compact: return 3
        case .specialized: return 4
        }
    }
}

public enum SpeedTier: Int, Sendable, Hashable, Codable, Comparable {
    case slow = 1
    case balanced = 2
    case fast = 3
    case fastest = 4

    public static func < (lhs: SpeedTier, rhs: SpeedTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum QualityTier: Int, Sendable, Hashable, Codable, Comparable {
    case good = 1
    case better = 2
    case best = 3

    public static func < (lhs: QualityTier, rhs: QualityTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ModelDownloadSource: Sendable, Hashable, Codable {
    public let huggingFaceRepo: String
    public let subpath: String

    public init(huggingFaceRepo: String, subpath: String) {
        self.huggingFaceRepo = huggingFaceRepo
        self.subpath = subpath
    }
}

public struct ModelVariant: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let displayName: String
    public let tagline: String
    public let engineID: EngineID
    public let sizeBytes: Int64
    public let downloadSource: ModelDownloadSource
    public let category: ModelCategory
    public let speedTier: SpeedTier
    public let qualityTier: QualityTier
    public let languageScope: SupportedLanguages?
    public let badges: [String]

    public init(
        id: String,
        displayName: String,
        tagline: String,
        engineID: EngineID,
        sizeBytes: Int64,
        downloadSource: ModelDownloadSource,
        category: ModelCategory,
        speedTier: SpeedTier,
        qualityTier: QualityTier,
        languageScope: SupportedLanguages? = nil,
        badges: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.tagline = tagline
        self.engineID = engineID
        self.sizeBytes = sizeBytes
        self.downloadSource = downloadSource
        self.category = category
        self.speedTier = speedTier
        self.qualityTier = qualityTier
        self.languageScope = languageScope
        self.badges = badges
    }
}

extension SupportedLanguages: Codable {
    private enum Kind: String, Codable { case all, only }
    private enum CodingKeys: String, CodingKey { case kind, codes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .all: self = .all
        case .only: self = .only(try c.decode(Set<String>.self, forKey: .codes))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all:
            try c.encode(Kind.all, forKey: .kind)
        case .only(let codes):
            try c.encode(Kind.only, forKey: .kind)
            try c.encode(codes, forKey: .codes)
        }
    }
}
