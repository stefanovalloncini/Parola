import Foundation
import Testing
@testable import ParolaCore

@Suite("Auto-export engine")
struct AutoExportEngineTests {
    @Test("empty rules return no exports")
    func emptyRules() {
        let formats = AutoExportEngine.plannedFormats(rules: [], sourceExtension: "mp4")
        #expect(formats.isEmpty)
    }

    @Test("matching rule contributes its formats")
    func matchingRule() {
        let rule = AutoExportRule(sourceExtensions: ["mp4"], outputFormats: [.srt, .txt])
        let formats = AutoExportEngine.plannedFormats(rules: [rule], sourceExtension: "mp4")
        #expect(Set(formats) == [.srt, .txt])
    }

    @Test("non-matching rule contributes nothing")
    func nonMatching() {
        let rule = AutoExportRule(sourceExtensions: ["mp3"], outputFormats: [.srt])
        let formats = AutoExportEngine.plannedFormats(rules: [rule], sourceExtension: "mp4")
        #expect(formats.isEmpty)
    }

    @Test("disabled rule contributes nothing")
    func disabledRule() {
        let rule = AutoExportRule(sourceExtensions: ["mp4"], outputFormats: [.srt], enabled: false)
        let formats = AutoExportEngine.plannedFormats(rules: [rule], sourceExtension: "mp4")
        #expect(formats.isEmpty)
    }

    @Test("rule with no extensions matches any source")
    func emptyExtensionsMatchAny() {
        let rule = AutoExportRule(sourceExtensions: [], outputFormats: [.txt])
        #expect(AutoExportEngine.plannedFormats(rules: [rule], sourceExtension: "mp4") == [.txt])
        #expect(AutoExportEngine.plannedFormats(rules: [rule], sourceExtension: "wav") == [.txt])
    }

    @Test("disabled rule with no extensions still contributes nothing")
    func emptyExtensionsDisabled() {
        let rule = AutoExportRule(sourceExtensions: [], outputFormats: [.txt], enabled: false)
        #expect(AutoExportEngine.plannedFormats(rules: [rule], sourceExtension: "mp4").isEmpty)
    }

    @Test("multiple rules dedupe overlapping formats")
    func dedupe() {
        let r1 = AutoExportRule(sourceExtensions: ["mp4"], outputFormats: [.srt])
        let r2 = AutoExportRule(sourceExtensions: ["mp4"], outputFormats: [.srt, .txt])
        let formats = AutoExportEngine.plannedFormats(rules: [r1, r2], sourceExtension: "mp4")
        #expect(Set(formats) == [.srt, .txt])
        #expect(formats.count == 2)
    }

    @Test("nil source extension returns nothing")
    func nilExtension() {
        let rule = AutoExportRule(sourceExtensions: ["mp4"], outputFormats: [.srt])
        let formats = AutoExportEngine.plannedFormats(rules: [rule], sourceExtension: nil)
        #expect(formats.isEmpty)
    }

    @Test("rules match extensions case-insensitively")
    func caseInsensitive() {
        let rule = AutoExportRule(sourceExtensions: ["MP4"], outputFormats: [.srt])
        let formats = AutoExportEngine.plannedFormats(rules: [rule], sourceExtension: "mp4")
        #expect(Set(formats) == [.srt])
    }

    @Test("rule round-trips through JSON")
    func jsonRoundTrip() throws {
        let rule = AutoExportRule(sourceExtensions: ["mp4", "mov"], outputFormats: [.srt, .vtt])
        let data = try JSONEncoder().encode([rule])
        let decoded = try JSONDecoder().decode([AutoExportRule].self, from: data)
        #expect(decoded.count == 1)
        #expect(decoded.first?.sourceExtensions == ["mp4", "mov"])
        #expect(decoded.first?.outputFormats == [.srt, .vtt])
    }
}
