import Foundation
import Testing
@testable import ParolaCore

@Suite("VoiceID forms")
struct VoiceIDFormsTests {
    @Test("apple automatic round-trips through rawValue")
    func appleAutomaticRoundTrip() {
        let id = VoiceID.appleAutomatic
        #expect(id.rawValue == "apple:auto")
        #expect(id.kind == .appleAutomatic)
        #expect(VoiceID(rawValue: "apple:auto") == id)
    }

    @Test("apple identifier round-trips through rawValue")
    func appleIdentifierRoundTrip() {
        let id = VoiceID.apple(identifier: "com.apple.voice.premium.en-US.Ava")
        #expect(id.rawValue == "apple:com.apple.voice.premium.en-US.Ava")
        #expect(id.kind == .apple(identifier: "com.apple.voice.premium.en-US.Ava"))
        #expect(VoiceID(rawValue: id.rawValue) == id)
    }

    @Test("neural voice round-trips through rawValue")
    func neuralRoundTrip() {
        let id = VoiceID.neural(pack: "pocket-tts-italian", voice: "giovanni")
        #expect(id?.rawValue == "pocket-tts-italian/giovanni")
        #expect(id?.kind == .neural(pack: "pocket-tts-italian", voice: "giovanni"))
        #expect(VoiceID(rawValue: id!.rawValue) == id)
    }

    @Test("round-trips through JSON as a single string")
    func jsonRoundTrip() throws {
        let ids: [VoiceID] = [
            .appleAutomatic,
            .apple(identifier: "com.apple.voice.compact.it-IT.Alice"),
            VoiceID.neural(pack: "supertonic-3", voice: "F1")!,
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let decoder = JSONDecoder()
        for id in ids {
            let data = try encoder.encode(id)
            #expect(String(data: data, encoding: .utf8) == "\"\(id.rawValue)\"")
            let decoded = try decoder.decode(VoiceID.self, from: data)
            #expect(decoded == id)
        }
    }

    @Test("rejects malformed raw values", arguments: [
        "",
        "apple:",
        "Pocket/x",
        "a/b/c",
        "bad pack/x",
    ])
    func rejectsMalformed(_ rawValue: String) {
        #expect(VoiceID(rawValue: rawValue) == nil)
    }

    @Test("decoding a malformed string throws")
    func jsonRejectsMalformed() {
        let data = Data("\"apple:\"".utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(VoiceID.self, from: data)
        }
    }

    @Test("neural validates the pack and voice")
    func neuralValidation() {
        #expect(VoiceID.neural(pack: "supertonic-3", voice: "F1") != nil)
        #expect(VoiceID.neural(pack: "Pocket", voice: "x") == nil)
        #expect(VoiceID.neural(pack: "bad pack", voice: "x") == nil)
        #expect(VoiceID.neural(pack: "pocket-tts-italian", voice: "") == nil)
        #expect(VoiceID.neural(pack: "pocket-tts-italian", voice: "a/b") == nil)
        #expect(VoiceID.neural(pack: "", voice: "x") == nil)
    }
}
