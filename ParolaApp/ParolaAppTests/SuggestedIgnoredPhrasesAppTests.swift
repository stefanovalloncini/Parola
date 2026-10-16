import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Suggested ignored phrases in the app")
struct SuggestedIgnoredPhrasesAppTests {
    private func makeModel(_ defaults: UserDefaults) -> AppModel {
        AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("suggested-phrases"))
    }

    private func encoded(_ rules: [IgnoredSegmentRule]) throws -> Data {
        try JSONEncoder().encode(rules)
    }

    @Test("a new install is seeded with the suggested phrases, enabled")
    func seedsWhenKeyAbsent() {
        let model = makeModel(temporaryDefaults())
        #expect(model.ignoredSegmentRules.map(\.pattern) == SuggestedIgnoredPhrases.defaults)
        #expect(model.ignoredSegmentRules.allSatisfy { $0.enabled })
    }

    @Test("the seeded list is saved, so the next launch reads it back")
    func seedIsPersisted() {
        let defaults = temporaryDefaults()
        let first = makeModel(defaults)
        let second = makeModel(defaults)
        #expect(second.ignoredSegmentRules == first.ignoredSegmentRules)
    }

    @Test("an empty saved list is left empty")
    func emptyListStaysEmpty() throws {
        let defaults = temporaryDefaults()
        defaults.set(try encoded([]), forKey: "ignoredSegmentRules")
        let model = makeModel(defaults)
        #expect(model.ignoredSegmentRules.isEmpty)
    }

    @Test("add-suggested fills the gaps, skips duplicates and reports the count")
    func addSuggested() throws {
        let defaults = temporaryDefaults()
        defaults.set(try encoded([
            IgnoredSegmentRule(pattern: "thanks for watching"),
            IgnoredSegmentRule(pattern: "uh")
        ]), forKey: "ignoredSegmentRules")
        let model = makeModel(defaults)

        let added = model.addSuggestedIgnoredPhrases()

        #expect(added == SuggestedIgnoredPhrases.defaults.count - 1)
        #expect(model.ignoredSegmentRules.count == 2 + added)
        #expect(model.ignoredSegmentRules.prefix(2).map(\.pattern) == ["thanks for watching", "uh"])
        #expect(model.addSuggestedIgnoredPhrases() == 0)
    }

    @Test("a pane reset brings the suggested list back")
    func paneResetRestoresList() {
        let defaults = temporaryDefaults()
        let model = makeModel(defaults)
        model.ignoredSegmentRules = [IgnoredSegmentRule(pattern: "mine")]

        for key in SettingsPaneScope.ignoredSegments.resetKeys(features: .all) {
            defaults.removeObject(forKey: key)
        }
        model.loadIgnoredSegmentRules()

        #expect(model.ignoredSegmentRules.map(\.pattern) == SuggestedIgnoredPhrases.defaults)
    }

    @Test("reset-all clears the key, so the next load seeds the list again")
    func resetAllRestoresList() {
        let defaults = temporaryDefaults()
        let model = makeModel(defaults)
        model.ignoredSegmentRules = []

        for key in SettingsPaneScope.allCases.flatMap(\.defaultsKeys) {
            defaults.removeObject(forKey: key)
        }
        model.loadIgnoredSegmentRules()

        #expect(model.ignoredSegmentRules.map(\.pattern) == SuggestedIgnoredPhrases.defaults)
    }

    @Test("importing settings keeps exactly the rules in the file")
    func importKeepsFileRules() throws {
        let defaults = temporaryDefaults()
        let model = makeModel(defaults)
        let fileRules = [IgnoredSegmentRule(pattern: "only this")]
        let envelope: [String: Any] = ["__type": "data", "value": try encoded(fileRules).base64EncodedString()]

        SettingsExportService.apply(["ignoredSegmentRules": envelope], defaults: defaults)
        model.loadIgnoredSegmentRules()
        #expect(model.ignoredSegmentRules == fileRules)

        let emptyEnvelope: [String: Any] = ["__type": "data", "value": try encoded([]).base64EncodedString()]
        SettingsExportService.apply(["ignoredSegmentRules": emptyEnvelope], defaults: defaults)
        model.loadIgnoredSegmentRules()
        #expect(model.ignoredSegmentRules.isEmpty)
    }

    @Test("a transcript loses the invented lines and keeps real speech")
    func postProcessDropsInventedLines() {
        let model = makeModel(temporaryDefaults())
        let segments = ["Hello there", "Thanks for watching!", "[Music]", "Thank you."].enumerated().map {
            TranscriptSegment(id: $0.offset, start: Double($0.offset), end: Double($0.offset) + 1, text: $0.element)
        }
        let out = model.postProcess(Transcript(segments: segments, language: "en", modelName: "tiny"))
        #expect(out.segments.map(\.text) == ["Hello there", "Thank you."])
    }

    @Test("the pane's Reset and the model's reload bring the suggested list back")
    func paneResetThroughTheService() {
        let previous = DefaultsStore.current
        let defaults = temporaryDefaults()
        DefaultsStore.current = defaults
        defer { DefaultsStore.current = previous }
        let model = makeModel(defaults)
        model.ignoredSegmentRules = [IgnoredSegmentRule(pattern: "mine")]

        SettingsResetService.reset(scope: .ignoredSegments)
        model.reloadSettings()

        #expect(model.ignoredSegmentRules.map(\.pattern) == SuggestedIgnoredPhrases.defaults)
    }

    @Test("importing a subtitle file keeps its tags with the suggested rules on")
    func subtitleImportRunsNoIgnoreRules() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SuggestedPhrasesImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let srt = """
        1
        00:00:00,000 --> 00:00:02,000
        [Music]

        2
        00:00:02,500 --> 00:00:04,000
        ♪♪

        3
        00:00:04,500 --> 00:00:06,000
        (upbeat music)

        4
        00:00:06,500 --> 00:00:08,000
        Thanks for watching!
        """
        let url = scratch.appendingPathComponent("tags.srt")
        try Data(srt.utf8).write(to: url)
        let model = makeModel(temporaryDefaults())
        #expect(model.ignoredSegmentRules.count == SuggestedIgnoredPhrases.defaults.count)

        model.importSubtitle(fileURL: url)

        #expect(model.transcript?.segments.map(\.text) == ["[Music]", "♪♪", "(upbeat music)", "Thanks for watching!"])
    }
}
