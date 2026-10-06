import Foundation
import Testing
import ParolaCore
import ParolaSpeech

@Suite("Speech log tokens")
struct LogSafeSpeechTests {
    @Test("engine kinds log their raw value")
    func engineKinds() {
        let tokens = SpeechEngineKind.allCases.map(\.logToken)
        #expect(tokens == ["apple", "supertonic", "pocket", "qwen"])
    }

    @Test("apple automatic logs as apple:auto")
    func appleAutomatic() {
        #expect(VoiceToken(.appleAutomatic).logToken == "apple:auto")
        #expect(VoiceToken(.appleAutomatic, appleQuality: .premium).logToken == "apple:auto")
    }

    @Test("an Apple voice logs its quality, never its identifier", arguments: [
        ("com.apple.voice.premium.en-US.Ava", VoiceToken.AppleQuality.premium, "apple:premium"),
        ("com.apple.voice.enhanced.it-IT.Federica", .enhanced, "apple:enhanced"),
        ("com.apple.voice.compact.en-US.Samantha", .default, "apple:default"),
        ("com.apple.eloquence.en-US.Rocko", .default, "apple:default"),
        ("com.apple.speech.personalvoice.4F8C2A91-7D3E-4B6A-9E12-0C5D8F3A2B71", .personal, "apple:personal"),
        ("Stefano's Voice", .personal, "apple:personal"),
    ])
    func appleIdentifierNeverLogged(identifier: String, quality: VoiceToken.AppleQuality, expected: String) throws {
        let voice = try #require(VoiceID.apple(identifier: identifier))
        let token = VoiceToken(voice, appleQuality: quality).logToken
        #expect(token == expected)
        let tail = identifier.split(separator: ".").last.map(String.init) ?? identifier
        #expect(!token.contains(tail))
        #expect(!token.contains(identifier))
    }

    @Test("an Apple voice with no known quality logs the scheme alone")
    func appleWithoutQuality() throws {
        let voice = try #require(VoiceID.apple(identifier: "com.apple.voice.premium.en-US.Ava"))
        #expect(VoiceToken(voice).logToken == "apple")
    }

    @Test("a neural voice logs its pack id only", arguments: [
        ("pocket-tts-italian", "giovanni"),
        ("supertonic-3", "F1"),
        ("qwen3-tts-0.6b", "serena"),
    ])
    func neuralPackOnly(pack: String, voice: String) throws {
        let id = try #require(VoiceID.neural(pack: pack, voice: voice))
        let token = VoiceToken(id).logToken
        #expect(token == pack)
        #expect(!token.contains(voice))
    }

    @Test("a voice that didn't parse logs unrecognized", arguments: [
        "", "apple:", "apple: Ava", "garbage", "Pocket/giovanni", "/giovanni", "supertonic-3/",
    ])
    func garbage(raw: String) {
        let voice = VoiceID(rawValue: raw)
        #expect(voice == nil)
        #expect(VoiceToken(voice).logToken == "unrecognized")
    }

    @Test("quality comes from the descriptor, and Personal Voice wins over its quality")
    func qualityFromDescriptor() {
        func descriptor(_ quality: VoiceDescriptor.Quality, personal: Bool) -> VoiceDescriptor {
            VoiceDescriptor(
                identifier: "com.apple.voice.x", name: "X", language: "en-US",
                quality: quality, isNovelty: false, isPersonal: personal, family: .standard
            )
        }
        #expect(VoiceToken.AppleQuality(descriptor(.premium, personal: false)) == .premium)
        #expect(VoiceToken.AppleQuality(descriptor(.enhanced, personal: false)) == .enhanced)
        #expect(VoiceToken.AppleQuality(descriptor(.default, personal: false)) == .default)
        #expect(VoiceToken.AppleQuality(descriptor(.premium, personal: true)) == .personal)
    }

    @Test("a log message carries the token, not the voice")
    func logMessageInterpolation() throws {
        let voice = try #require(VoiceID.apple(identifier: "com.apple.speech.personalvoice.4F8C2A91"))
        let message: LogMessage = "reading with \(VoiceToken(voice, appleQuality: .personal)) on \(SpeechEngineKind.apple)"
        #expect(message.rendered == "reading with apple:personal on apple")
    }
}
