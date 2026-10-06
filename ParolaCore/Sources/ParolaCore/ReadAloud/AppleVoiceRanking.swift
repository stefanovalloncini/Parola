import Foundation

/// Orders installed Apple voices for a language so "Automatic" picks the most natural one.
public enum AppleVoiceRanking {
    public static func rank(
        _ voices: [VoiceDescriptor],
        forLanguage code: String,
        preferredRegions: [String],
        unusable: Set<String> = []
    ) -> [VoiceDescriptor] {
        let targetBase = SpokenLanguage.baseCode(code)
        let regions = preferredRegions.map { $0.uppercased() }
        return voices
            .filter { voice in
                !voice.isNovelty
                    && !unusable.contains(voice.identifier)
                    && matches(voiceLanguage: voice.language, targetBase: targetBase)
            }
            .sorted { isOrderedBefore($0, $1, preferredRegions: regions) }
    }

    public static func best(
        _ voices: [VoiceDescriptor],
        forLanguage code: String,
        preferredRegions: [String],
        unusable: Set<String> = []
    ) -> VoiceDescriptor? {
        rank(voices, forLanguage: code, preferredRegions: preferredRegions, unusable: unusable)
            .first { !$0.isPersonal }
    }

    private static func matches(voiceLanguage: String, targetBase: String) -> Bool {
        if SpokenLanguage.baseCode(voiceLanguage) == targetBase {
            return true
        }
        return targetBase == "yue" && voiceLanguage.caseInsensitiveCompare("zh-HK") == .orderedSame
    }

    private static func isOrderedBefore(_ lhs: VoiceDescriptor, _ rhs: VoiceDescriptor, preferredRegions: [String]) -> Bool {
        let lhsTier = tier(for: lhs)
        let rhsTier = tier(for: rhs)
        if lhsTier != rhsTier { return lhsTier < rhsTier }

        let lhsFamily = familyRank(lhs.family)
        let rhsFamily = familyRank(rhs.family)
        if lhsFamily != rhsFamily { return lhsFamily < rhsFamily }

        let lhsRegion = regionRank(lhs.language, preferredRegions: preferredRegions)
        let rhsRegion = regionRank(rhs.language, preferredRegions: preferredRegions)
        if lhsRegion != rhsRegion { return lhsRegion < rhsRegion }

        return lhs.name < rhs.name
    }

    private static func tier(for voice: VoiceDescriptor) -> Int {
        if voice.isPersonal { return 0 }
        switch voice.quality {
        case .premium: return 0
        case .enhanced: return 1
        case .default: return 2
        }
    }

    private static func familyRank(_ family: VoiceDescriptor.Family) -> Int {
        switch family {
        case .standard: return 0
        case .eloquence: return 1
        case .macinTalk: return 2
        }
    }

    private static func regionRank(_ language: String, preferredRegions: [String]) -> Int {
        guard let region = Locale.Language(identifier: language).region?.identifier else {
            return preferredRegions.count
        }
        return preferredRegions.firstIndex(of: region) ?? preferredRegions.count
    }
}
