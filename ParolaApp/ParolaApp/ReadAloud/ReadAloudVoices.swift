import Foundation
import ParolaCore
import ParolaSpeech

struct AppleVoiceInventory: Equatable, Sendable {
    var voices: [VoiceDescriptor] = []
    var unusable: Set<String> = []
}

enum PersonalVoiceStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case unsupported
}

enum PersonalVoicePresentation: Equatable {
    case askButton
    case deniedNote
    case granted(voices: Int)
    case hidden
}

struct VoiceMenuEntry: Identifiable, Equatable {
    let voice: VoiceID
    let title: String
    let isUsable: Bool

    var id: String { voice.rawValue }
}

enum ReadAloudVoiceDecision: Equatable {
    case read(VoiceID)
    case chooser
    case noVoice
}

enum ReadAloudVoices {
    static let systemSettingsURLs: [URL] = [
        "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?AX_SPEECH_VOICES",
        "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?AX_FEATURE_SPOKENCONTENT",
        "x-apple.systempreferences:com.apple.Accessibility-Settings.extension",
    ].compactMap(URL.init(string:))

    static func key(for language: String) -> String {
        SpokenLanguage.baseCode(language)
    }

    static func decide(saved: VoiceID?, savedIsUsable: Bool, neuralOffers: Bool, appleVoices: Bool) -> ReadAloudVoiceDecision {
        if let saved, savedIsUsable { return .read(saved) }
        guard appleVoices || neuralOffers else { return .noVoice }
        if saved != nil || neuralOffers { return .chooser }
        return .read(.appleAutomatic)
    }

    static func candidates(for language: String, in inventory: AppleVoiceInventory) -> [VoiceDescriptor] {
        AppleVoiceRanking.rank(
            inventory.voices, forLanguage: language, preferredRegions: preferredRegions, unusable: inventory.unusable
        )
    }

    static func unusableVoices(for language: String, in inventory: AppleVoiceInventory) -> [VoiceDescriptor] {
        let all = AppleVoiceRanking.rank(inventory.voices, forLanguage: language, preferredRegions: preferredRegions)
        return all.filter { inventory.unusable.contains($0.identifier) }
    }

    static func hasAppleVoice(for language: String, in inventory: AppleVoiceInventory) -> Bool {
        AppleVoiceRanking.best(
            inventory.voices, forLanguage: language, preferredRegions: preferredRegions, unusable: inventory.unusable
        ) != nil
    }

    static func isUsable(_ voice: VoiceID, for language: String, in inventory: AppleVoiceInventory) -> Bool {
        switch voice.kind {
        case .appleAutomatic:
            return hasAppleVoice(for: language, in: inventory)
        case .apple(let identifier):
            return candidates(for: language, in: inventory).contains { $0.identifier == identifier }
        case .neural:
            return false
        }
    }

    static func menuEntries(for language: String, in inventory: AppleVoiceInventory) -> [VoiceMenuEntry] {
        guard hasAppleVoice(for: language, in: inventory) else { return [] }
        var entries = [VoiceMenuEntry(voice: .appleAutomatic, title: String(localized: "Automatic (best installed)"), isUsable: true)]
        for voice in candidates(for: language, in: inventory) {
            guard let id = VoiceID.apple(identifier: voice.identifier) else { continue }
            entries.append(VoiceMenuEntry(voice: id, title: title(of: voice), isUsable: true))
        }
        for voice in unusableVoices(for: language, in: inventory) {
            guard let id = VoiceID.apple(identifier: voice.identifier) else { continue }
            let title = String(localized: "\(voice.name) · Can't read aloud with this voice.")
            entries.append(VoiceMenuEntry(voice: id, title: title, isUsable: false))
        }
        return entries
    }

    private static func title(of voice: VoiceDescriptor) -> String {
        if voice.isPersonal { return String(localized: "\(voice.name) · Personal Voice") }
        switch voice.quality {
        case .premium: return String(localized: "\(voice.name) · Premium")
        case .enhanced: return String(localized: "\(voice.name) · Enhanced")
        case .default: return voice.name
        }
    }

    static func neuralOffers(for language: String) -> [VoiceOption] {
        let key = key(for: language)
        return VoiceCatalog.packs.filter { $0.engine != .apple }.flatMap { $0.voicesByLanguage[key] ?? [] }
    }

    static func displayName(of voice: VoiceID, language: String, in inventory: AppleVoiceInventory) -> String {
        switch voice.kind {
        case .appleAutomatic:
            return String(localized: "Automatic (best installed)")
        case .apple(let identifier):
            return inventory.voices.first { $0.identifier == identifier }?.name ?? String(localized: "Built-in voice")
        case .neural(let pack, let name):
            let option = VoiceCatalog.packs.first { $0.id == pack }?.voicesByLanguage[key(for: language)]?
                .first { $0.id == voice }
            return option?.displayName ?? name
        }
    }

    static func spokenName(of voice: VoiceID, language: String, in inventory: AppleVoiceInventory) -> String {
        switch voice.kind {
        case .appleAutomatic:
            let best = AppleVoiceRanking.best(
                inventory.voices, forLanguage: language, preferredRegions: preferredRegions, unusable: inventory.unusable
            )
            return best?.name ?? String(localized: "the built-in voice")
        case .apple, .neural:
            return displayName(of: voice, language: language, in: inventory)
        }
    }

    static func rows(known: [String], saved: [String], interface: String, translations: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for code in known + saved + [interface] + translations {
            guard let real = SpokenLanguage.realCode(code) else { continue }
            let base = key(for: real)
            if seen.insert(base).inserted { result.append(base) }
        }
        return result.sorted {
            (LanguageDisplay.name(for: $0) ?? $0).localizedCaseInsensitiveCompare(LanguageDisplay.name(for: $1) ?? $1) == .orderedAscending
        }
    }

    static func personalVoice(status: PersonalVoiceStatus, personalVoices: Int) -> PersonalVoicePresentation {
        switch status {
        case .unsupported: .hidden
        case .notDetermined: .askButton
        case .denied: .deniedNote
        case .authorized: .granted(voices: personalVoices)
        }
    }

    static func decodeSaved(_ json: String?) -> [String: VoiceID] {
        guard let data = json?.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return raw.reduce(into: [:]) { result, pair in
            if let voice = VoiceID(rawValue: pair.value) { result[key(for: pair.key)] = voice }
        }
    }

    static func encodeSaved(_ saved: [String: VoiceID]) -> String? {
        guard !saved.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(saved.mapValues(\.rawValue))).flatMap { String(data: $0, encoding: .utf8) }
    }

    static let sampleSentences: [String: String] = [
        "en": "This is how I will read your transcript.",
        "it": "Così leggerò la tua trascrizione.",
        "fr": "Voici comment je lirai votre transcription.",
        "de": "So werde ich Ihr Transkript vorlesen.",
        "es": "Así leeré tu transcripción.",
        "pt": "É assim que vou ler a sua transcrição.",
        "nl": "Zo ga ik je transcript voorlezen.",
        "ja": "これが文字起こしを読み上げる声です。",
        "zh": "这就是我朗读你的转录文本的声音。",
    ]

    static func sampleText(for language: String, transcriptSentence: String?) -> String {
        if let known = sampleSentences[key(for: language)] { return known }
        if let sentence = transcriptSentence?.trimmingCharacters(in: .whitespacesAndNewlines),
           sentence.split(whereSeparator: \.isWhitespace).count >= 4 {
            return String(sentence.prefix(200))
        }
        return sampleSentence(for: language)
    }

    static func settingsEntries(for language: String, in inventory: AppleVoiceInventory, saved: VoiceID?) -> [VoiceMenuEntry] {
        let entries = menuEntries(for: language, in: inventory)
        guard !entries.isEmpty, let saved, saved != .appleAutomatic,
              !entries.contains(where: { $0.voice == saved && $0.isUsable }) else { return entries }
        return [VoiceMenuEntry(voice: saved, title: String(localized: "Voice not installed"), isUsable: false)] + entries
    }

    static func sampleSentence(for language: String) -> String {
        sampleSentences[key(for: language)] ?? sampleSentences["en"] ?? ""
    }

    static var preferredRegions: [String] {
        Locale.preferredLanguages.compactMap { Locale.Language(identifier: $0).region?.identifier }
    }
}
