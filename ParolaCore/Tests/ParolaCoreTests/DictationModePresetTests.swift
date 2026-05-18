import Foundation
import Testing
@testable import ParolaCore

@Suite("Dictation mode preset")
struct DictationModePresetTests {
    @Test("built-in presets cover voice, message, email")
    func builtInCoverage() {
        let names = DictationModePreset.builtIns.map(\.name)
        #expect(names.contains("Voice"))
        #expect(names.contains("Message"))
        #expect(names.contains("Email"))
    }

    @Test("voice preset has no cleanup prompt")
    func voiceHasNoPrompt() {
        let voice = DictationModePreset.builtIns.first { $0.name == "Voice" }
        #expect(voice?.promptID == nil)
    }

    @Test("message preset maps to the Casual built-in prompt")
    func messageMapsToCasual() {
        let message = DictationModePreset.builtIns.first { $0.name == "Message" }
        let casual = Prompt.builtIns.first { $0.name == "Casual" }
        #expect(message?.promptID == casual?.id)
    }

    @Test("email preset maps to the Professional tone built-in prompt")
    func emailMapsToProfessional() {
        let email = DictationModePreset.builtIns.first { $0.name == "Email" }
        let professional = Prompt.builtIns.first { $0.name == "Professional tone" }
        #expect(email?.promptID == professional?.id)
    }

    @Test("ids are stable and unique")
    func uniqueIDs() {
        let ids = Set(DictationModePreset.builtIns.map(\.id))
        #expect(ids.count == DictationModePreset.builtIns.count)
    }
}
