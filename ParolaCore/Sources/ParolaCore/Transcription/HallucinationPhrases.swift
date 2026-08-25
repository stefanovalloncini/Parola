import Foundation

/// Lines Whisper decodes out of silence rather than speech: subtitle-credit boilerplate and
/// video outros it learned from its training subtitles. Matched against a whole segment,
/// ignoring case and trailing punctuation.
public enum HallucinationPhrases {
    public static let defaults: [String] = [
        "Thank you.",
        "Thank you for watching.",
        "Thanks for watching.",
        "Thanks for watching!",
        "Thank you for watching!",
        "Please subscribe to my channel.",
        "Subtitles by the Amara.org community",
        "Subtitles by SteamTeamExtra",
        "Sottotitoli e revisione a cura di QTSS",
        "Sottotitoli a cura di QTSS",
        "Sottotitoli creati dalla comunità Amara.org",
        "Grazie per aver guardato il video.",
        "Subtítulos realizados por la comunidad de Amara.org",
        "Gracias por ver el video.",
        "Sous-titres réalisés par la communauté d'Amara.org",
        "Merci d'avoir regardé cette vidéo.",
        "Untertitel der Amara.org-Community",
        "Untertitelung aufgrund der Amara.org-Community",
        "Vielen Dank fürs Zuschauen.",
        "Legendas pela comunidade Amara.org",
        "Ondertiteling door de Amara.org gemeenschap",
        "시청해주셔서 감사합니다.",
        "시청해 주셔서 감사합니다.",
        "구독과 좋아요 부탁드립니다.",
        "ご視聴ありがとうございました。",
        "ご視聴ありがとうございます。",
        "Продолжение следует...",
        "Субтитры сделал DimaTorzok",
        "Субтитры создавал DimaTorzok",
        "字幕由Amara.org社区提供",
        "谢谢观看"
    ]

    static let matchSet: Set<String> = Set(defaults.map(normalized))

    static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: trimmed)
    }

    private static let trimmed = CharacterSet(charactersIn: ".!?…。！？,、♪-—")
        .union(.whitespacesAndNewlines)
}
