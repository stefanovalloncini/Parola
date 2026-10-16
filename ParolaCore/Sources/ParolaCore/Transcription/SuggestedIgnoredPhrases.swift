import Foundation

/// Lines speech models invent over silence, music or noise, seeded as editable ignore rules.
/// Phrases people plausibly say as a whole segment ("Thank you.", "Bye.") stay out.
public enum SuggestedIgnoredPhrases {
    public static let defaults: [String] = [
        "Thanks for watching!",
        "Thank you for watching.",
        "Thanks for watching and see you next time.",
        "Please subscribe to my channel.",
        "Don't forget to like and subscribe!",
        "Like and subscribe.",
        "See you in the next video!",
        "[Music]",
        "[Applause]",
        "[BLANK_AUDIO]",
        "[silence]",
        "[no speech]",
        "(music)",
        "(upbeat music)",
        "♪",
        "[Música]",
        "[Musique]",
        "[Musik]",
        "Grazie per la visione!",
        "Grazie per aver guardato il video!",
        "Iscriviti al canale!",
        "¡Suscríbete!",
        "Gracias por ver el video.",
        "Gracias por ver el vídeo.",
        "Merci d'avoir regardé.",
        "Merci d'avoir regardé cette vidéo !",
        "Abonnez-vous !",
        "Danke fürs Zuschauen!",
        "Vielen Dank fürs Zuschauen.",
        "Untertitel im Auftrag des ZDF für funk, 2017",
        "Untertitel im Auftrag des ZDF, 2018",
        "Untertitel im Auftrag des ZDF, 2020",
        "Untertitelung des ZDF, 2020",
        "Obrigado por assistir!",
        "Obrigado por assistir ao vídeo.",
        "Inscreva-se no canal!",
        "Продолжение следует...",
        "Спасибо за просмотр!",
        "Подписывайтесь на канал!",
        "Редактор субтитров А.Семкин Корректор А.Егорова",
        "ご視聴ありがとうございました",
        "チャンネル登録をお願いします",
        "谢谢观看",
        "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目"
    ]

    public static func rules() -> [IgnoredSegmentRule] {
        defaults.map { IgnoredSegmentRule(pattern: $0) }
    }

    /// The suggested rules whose phrase no existing rule already covers, enabled or not.
    public static func missing(from existing: [IgnoredSegmentRule]) -> [IgnoredSegmentRule] {
        let covered = Set(
            existing
                .filter { !$0.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { IgnoredSegments.normalized($0.pattern) }
        )
        return rules().filter { !covered.contains(IgnoredSegments.normalized($0.pattern)) }
    }
}
