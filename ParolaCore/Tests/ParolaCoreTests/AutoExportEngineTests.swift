import Foundation
import Testing
@testable import ParolaCore

@Suite("Auto-export engine")
struct AutoExportEngineTests {
    private let library = ExportPreset.builtIns
    private var srt: UUID { ExportPreset.builtIn(for: .srt)!.id }
    private var txt: UUID { ExportPreset.builtIn(for: .txt)!.id }

    @Test("empty rules return no exports")
    func emptyRules() {
        #expect(AutoExportEngine.plannedPresets(rules: [], sourceExtension: "mp4", presets: library).isEmpty)
    }

    @Test("matching rule contributes its presets")
    func matchingRule() {
        let rule = AutoExportRule(sourceExtensions: ["mp4"], presetIDs: [srt, txt])
        let presets = AutoExportEngine.plannedPresets(rules: [rule], sourceExtension: "mp4", presets: library)
        #expect(presets.map(\.id) == [srt, txt])
    }

    @Test("non-matching rule contributes nothing")
    func nonMatching() {
        let rule = AutoExportRule(sourceExtensions: ["mp3"], presetIDs: [srt])
        #expect(AutoExportEngine.plannedPresets(rules: [rule], sourceExtension: "mp4", presets: library).isEmpty)
    }

    @Test("disabled rule contributes nothing")
    func disabledRule() {
        let rule = AutoExportRule(sourceExtensions: ["mp4"], presetIDs: [srt], enabled: false)
        #expect(AutoExportEngine.plannedPresets(rules: [rule], sourceExtension: "mp4", presets: library).isEmpty)
    }

    @Test("rule with no extensions matches any source")
    func emptyExtensionsMatchAny() {
        let rule = AutoExportRule(sourceExtensions: [], presetIDs: [txt])
        #expect(AutoExportEngine.plannedPresets(rules: [rule], sourceExtension: "mp4", presets: library).map(\.id) == [txt])
        #expect(AutoExportEngine.plannedPresets(rules: [rule], sourceExtension: "wav", presets: library).map(\.id) == [txt])
    }

    @Test("disabled rule with no extensions still contributes nothing")
    func emptyExtensionsDisabled() {
        let rule = AutoExportRule(sourceExtensions: [], presetIDs: [txt], enabled: false)
        #expect(AutoExportEngine.plannedPresets(rules: [rule], sourceExtension: "mp4", presets: library).isEmpty)
    }

    @Test("multiple rules dedupe overlapping presets")
    func dedupe() {
        let first = AutoExportRule(sourceExtensions: ["mp4"], presetIDs: [srt])
        let second = AutoExportRule(sourceExtensions: ["mp4"], presetIDs: [srt, txt])
        let presets = AutoExportEngine.plannedPresets(rules: [first, second], sourceExtension: "mp4", presets: library)
        #expect(presets.map(\.id) == [srt, txt])
    }

    @Test("a preset the library no longer holds is skipped")
    func unknownPresetIsSkipped() {
        let rule = AutoExportRule(sourceExtensions: ["mp4"], presetIDs: [UUID(), txt])
        let presets = AutoExportEngine.plannedPresets(rules: [rule], sourceExtension: "mp4", presets: library)
        #expect(presets.map(\.id) == [txt])
    }

    @Test("nil source extension returns nothing")
    func nilExtension() {
        let rule = AutoExportRule(sourceExtensions: ["mp4"], presetIDs: [srt])
        #expect(AutoExportEngine.plannedPresets(rules: [rule], sourceExtension: nil, presets: library).isEmpty)
    }

    @Test("rules match extensions case-insensitively")
    func caseInsensitive() {
        let rule = AutoExportRule(sourceExtensions: ["MP4"], presetIDs: [srt])
        let presets = AutoExportEngine.plannedPresets(rules: [rule], sourceExtension: "mp4", presets: library)
        #expect(presets.map(\.id) == [srt])
    }

    @Test("rule round-trips through JSON")
    func jsonRoundTrip() throws {
        let rule = AutoExportRule(sourceExtensions: ["mp4", "mov"], presetIDs: [srt, txt])
        let data = try JSONEncoder().encode([rule])
        let decoded = try JSONDecoder().decode([AutoExportRule].self, from: data)
        #expect(decoded.count == 1)
        #expect(decoded.first?.sourceExtensions == ["mp4", "mov"])
        #expect(decoded.first?.presetIDs == [srt, txt])
    }

    @Test("a rule saved with output formats decodes onto the built-in presets")
    func migratesLegacyOutputFormats() throws {
        let legacy = """
        [{"id":"11111111-1111-1111-1111-111111111111","sourceExtensions":["mp4"],"outputFormats":["srt","txt"],"enabled":true}]
        """
        let decoded = try JSONDecoder().decode([AutoExportRule].self, from: Data(legacy.utf8))
        #expect(decoded.first?.presetIDs == [txt, srt])
        #expect(decoded.first?.enabled == true)
        #expect(decoded.first?.sourceExtensions == ["mp4"])
    }

    @Test("a legacy format without a built-in preset keeps its own stable preset id")
    func migratesFormatWithoutABuiltIn() throws {
        let legacy = """
        [{"id":"11111111-1111-1111-1111-111111111111","sourceExtensions":["mp4"],"outputFormats":["html","csv"],"enabled":true}]
        """
        let decoded = try JSONDecoder().decode([AutoExportRule].self, from: Data(legacy.utf8))
        #expect(decoded.first?.presetIDs == [ExportPreset.defaultID(for: .html), ExportPreset.defaultID(for: .csv)])
        #expect(ExportPreset.formatPreset(id: ExportPreset.defaultID(for: .csv))?.name == "CSV")
        #expect(ExportPreset.formatPreset(id: ExportPreset.defaultID(for: .html))?.name == "HTML")
    }
}
