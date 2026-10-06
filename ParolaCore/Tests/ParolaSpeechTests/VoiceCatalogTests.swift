import Foundation
import Testing
import ParolaCore
import ParolaSpeech

@Suite("VoiceCatalog")
struct VoiceCatalogTests {
    @Test("pack ids are unique, and each pack's voices are unique per language and carry its pack id")
    func uniqueIDs() {
        let packIDs = VoiceCatalog.packs.map(\.id)
        let duplicateVoices = VoiceCatalog.packs.flatMap { pack in
            pack.voicesByLanguage
                .filter { _, voices in Set(voices.map(\.id)).count != voices.count }
                .map { language, _ in "\(pack.id) \(language)" }
        }
        let foreignVoices = VoiceCatalog.packs.flatMap { pack in
            pack.voicesByLanguage.values.joined()
                .filter { voice in
                    guard case .neural(let owner, _) = voice.id.kind else { return true }
                    return owner != pack.id
                }
                .map(\.id.rawValue)
        }
        #expect(Set(packIDs).count == packIDs.count)
        #expect(duplicateVoices.isEmpty, Comment(rawValue: duplicateVoices.joined(separator: ", ")))
        #expect(foreignVoices.isEmpty, Comment(rawValue: foreignVoices.joined(separator: ", ")))
    }

    @Test("the Apple system pack is listed, owns nothing on disk, and finds its voices at run time")
    func applePack() throws {
        let listed = VoiceCatalog.packs.first { $0.id == "apple" }
        let apple = try #require(listed)
        #expect(apple == VoiceCatalog.apple)
        #expect(apple.engine == .apple)
        #expect(apple.sizeBytes == 0)
        #expect(apple.parts.isEmpty)
        #expect(apple.voicesByLanguage.isEmpty)
        #expect(apple.supersededInstallDirectories.isEmpty)
        #expect(apple.licence == nil)
    }

    @Test("every offered language has exactly one default voice")
    func oneDefaultPerLanguage() {
        let offenders = VoiceCatalog.packs.flatMap { pack in
            pack.voicesByLanguage
                .filter { _, voices in voices.filter(\.isDefault).count != 1 }
                .map { language, _ in "\(pack.id) \(language)" }
        }
        #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: ", ")))
    }

    @Test("no voice is recommended yet")
    func recommendedEmpty() {
        #expect(VoiceCatalog.recommended.isEmpty)
    }
}
