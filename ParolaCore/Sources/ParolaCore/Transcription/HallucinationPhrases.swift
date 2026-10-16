import Foundation

/// Subtitle-credit lines Whisper decodes out of silence, learned from its training subtitles.
/// Only lines nobody speaks belong here — an outro like "Thank you." is real speech and stays.
/// Matched against a whole segment, ignoring case and trailing punctuation.
public enum HallucinationPhrases {
    public static let defaults: [String] = [
        "Subtitles by the Amara.org community",
        "Subtitles by SteamTeamExtra",
        "Sottotitoli e revisione a cura di QTSS",
        "Sottotitoli a cura di QTSS",
        "Sottotitoli creati dalla comunità Amara.org",
        "Subtítulos realizados por la comunidad de Amara.org",
        "Sous-titres réalisés par la communauté d'Amara.org",
        "Untertitel der Amara.org-Community",
        "Untertitelung aufgrund der Amara.org-Community",
        "Legendas pela comunidade Amara.org",
        "Ondertiteling door de Amara.org gemeenschap",
        "Субтитры сделал DimaTorzok",
        "Субтитры создавал DimaTorzok",
        "字幕由Amara.org社区提供"
    ]

    static let matchSet: Set<String> = Set(defaults.map(IgnoredSegments.normalized))
}
