import Foundation

public struct SummaryOptions: Codable, Sendable, Equatable {
    public var includeTimestamps = true
    public var includeSpeakers = false
    public var sections = true
    public var bulletPoints = false
    public var actionItems = true
    public var keyPointsOnly = false
    public var outputLanguage: String?
    public var customPrompt: String?

    public init(
        includeTimestamps: Bool = true,
        includeSpeakers: Bool = false,
        sections: Bool = true,
        bulletPoints: Bool = false,
        actionItems: Bool = true,
        keyPointsOnly: Bool = false,
        outputLanguage: String? = nil,
        customPrompt: String? = nil
    ) {
        self.includeTimestamps = includeTimestamps
        self.includeSpeakers = includeSpeakers
        self.sections = sections
        self.bulletPoints = bulletPoints
        self.actionItems = actionItems
        self.keyPointsOnly = keyPointsOnly
        self.outputLanguage = outputLanguage
        self.customPrompt = customPrompt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        includeTimestamps = try c.decodeIfPresent(Bool.self, forKey: .includeTimestamps) ?? true
        includeSpeakers = try c.decodeIfPresent(Bool.self, forKey: .includeSpeakers) ?? false
        sections = try c.decodeIfPresent(Bool.self, forKey: .sections) ?? true
        bulletPoints = try c.decodeIfPresent(Bool.self, forKey: .bulletPoints) ?? false
        actionItems = try c.decodeIfPresent(Bool.self, forKey: .actionItems) ?? true
        keyPointsOnly = try c.decodeIfPresent(Bool.self, forKey: .keyPointsOnly) ?? false
        outputLanguage = try c.decodeIfPresent(String.self, forKey: .outputLanguage)
        customPrompt = try c.decodeIfPresent(String.self, forKey: .customPrompt)
    }

    public static let `default` = SummaryOptions()
}
