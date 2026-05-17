import Foundation
import Testing
@testable import ParolaCore

@Suite("Prompt rewrite presets")
struct PromptRewritePresetsTests {
    @Test("rewritePresets has exactly four entries")
    func presetCount() {
        #expect(Prompt.rewritePresets.count == 4)
    }

    @Test("rewritePresets are ordered formal, casual, concise, bullets")
    func presetOrder() {
        let names = Prompt.rewritePresets.map(\.name)
        #expect(names == ["Professional tone", "Casual", "Concise", "Bullet points"])
    }

    @Test("all presets are built-in with non-empty instructions")
    func presetsBuiltIn() {
        for preset in Prompt.rewritePresets {
            #expect(preset.isBuiltIn)
            #expect(!preset.instructions.isEmpty)
        }
    }

    @Test("preset UUIDs are stable and distinct")
    func presetIDs() {
        let ids = Set(Prompt.rewritePresets.map(\.id))
        #expect(ids.count == 4)
    }

    @Test("casual and concise are also exposed in Prompt.builtIns")
    func builtInsContainNewPresets() {
        let builtInNames = Set(Prompt.builtIns.map(\.name))
        #expect(builtInNames.contains("Casual"))
        #expect(builtInNames.contains("Concise"))
    }
}
