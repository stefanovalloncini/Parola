import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("AppModel term packs")
struct AppModelTermPacksTests {

    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("termpacks"))
    }

    private func writePack(_ pack: TermPack) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermPackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("pack.json")
        try TermPackIO.encode(pack).write(to: url)
        return url
    }

    @Test("importing a term pack appends its rules to find/replace")
    func importMergesRules() async throws {
        let model = makeModel()
        model.findReplaceRules = []
        let url = try writePack(TermPack(
            name: "Test",
            locale: "en",
            rules: [
                TermPackRule(find: "kubernetes", replace: "Kubernetes"),
                TermPackRule(find: "postgres", replace: "Postgres"),
            ]
        ))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        await model.importTermPack(from: url)

        let allEnabled = model.findReplaceRules.allSatisfy { $0.enabled }
        #expect(model.findReplaceRules.map(\.find) == ["kubernetes", "postgres"])
        #expect(allEnabled)
        #expect(model.phase != .failed(message: ""))
    }

    @Test("importing a term pack skips rules already present")
    func importDeduplicates() async throws {
        let model = makeModel()
        model.findReplaceRules = [FindReplaceRule(find: "swift", replace: "Swift")]
        let url = try writePack(TermPack(
            name: "Test",
            locale: "en",
            rules: [
                TermPackRule(find: "swift", replace: "Swift"),
                TermPackRule(find: "xcode", replace: "Xcode"),
            ]
        ))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        await model.importTermPack(from: url)

        #expect(model.findReplaceRules.map(\.find) == ["swift", "xcode"])
    }

    @Test("importing a pack with empty finds drops those rules")
    func importDropsEmptyFinds() async throws {
        let model = makeModel()
        model.findReplaceRules = []
        let url = try writePack(TermPack(
            name: "Test",
            locale: "en",
            rules: [
                TermPackRule(find: "", replace: "ignored"),
                TermPackRule(find: "redis", replace: "Redis"),
            ]
        ))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        await model.importTermPack(from: url)

        #expect(model.findReplaceRules.map(\.find) == ["redis"])
    }

    @Test("importing from a missing file reports a failure")
    func importMissingFileFails() async {
        let model = makeModel()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")

        await model.importTermPack(from: missing)

        guard case .failed(let message) = model.phase else {
            Issue.record("expected a failed phase, got \(model.phase)")
            return
        }
        #expect(message.contains("term pack"))
    }

    @Test("importing malformed JSON reports a failure")
    func importMalformedFails() async throws {
        let model = makeModel()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermPackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("bad.json")
        try Data("not json".utf8).write(to: url)

        await model.importTermPack(from: url)

        guard case .failed = model.phase else {
            Issue.record("expected a failed phase, got \(model.phase)")
            return
        }
    }

    @Test("importing an unknown bundled pack reports a failure")
    func bundledUnknownFails() {
        let model = makeModel()

        model.importBundledTermPack(named: "no-such-pack")

        guard case .failed(let message) = model.phase else {
            Issue.record("expected a failed phase, got \(model.phase)")
            return
        }
        #expect(message.contains("no-such-pack"))
    }

    @Test("a known bundled pack, when its resource is present, merges its rules")
    func bundledKnownMerges() throws {
        let identifier = try #require(BundledTermPacks.identifiers.first)
        try #require(BundledTermPacks.load(identifier) != nil, "bundled term pack resource unavailable in this host")

        let model = makeModel()
        model.findReplaceRules = []
        model.importBundledTermPack(named: identifier)

        #expect(model.findReplaceRules.isEmpty == false)
        guard case .failed = model.phase else { return }
        Issue.record("import of a present bundled pack should not fail")
    }
}

@MainActor
@Suite("AppModel list import")
struct AppModelRuleListImportTests {
    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("rulelist"))
    }

    private func write(_ text: String, named name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RuleList-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test("a list file previews first and changes nothing")
    func previews() async throws {
        let model = makeModel()
        model.findReplaceRules = []
        let url = try write("cat,dog\nfoo,bar\n# c\n", named: "list.csv")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        await model.importRulesFile(from: url)

        #expect(model.findReplaceRules.isEmpty)
        #expect(model.pendingRuleImport?.newRuleCount == 2)
        #expect(model.pendingRuleImport?.skippedLines == 1)
        #expect(model.pendingRuleImport?.fileName == "list.csv")
    }

    @Test("the preview count leaves out rules already present")
    func previewExcludesDuplicates() async throws {
        let model = makeModel()
        model.findReplaceRules = [FindReplaceRule(find: "cat", replace: "dog", wholeWord: true)]
        let url = try write("cat -> dog\nfoo -> bar", named: "list.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        await model.importRulesFile(from: url)

        #expect(model.pendingRuleImport?.newRuleCount == 1)
    }

    @Test("a list that adds nothing says so")
    func nothingToImport() async throws {
        let model = makeModel()
        model.findReplaceRules = [FindReplaceRule(find: "cat", replace: "dog", wholeWord: true)]
        let url = try write("cat,dog", named: "list.csv")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        await model.importRulesFile(from: url)

        #expect(model.pendingRuleImport?.newRuleCount == 0)
        #expect(model.pendingRuleImport?.title == "Nothing to import")
    }

    @Test("the zero case still reports skipped lines")
    func nothingToImportShowsSkipped() async throws {
        let model = makeModel()
        model.findReplaceRules = [FindReplaceRule(find: "cat", replace: "dog", wholeWord: true)]
        let url = try write("cat,dog\nbroken\n", named: "list.csv")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        await model.importRulesFile(from: url)

        #expect(model.pendingRuleImport?.message.contains("1 line") == true)
    }

    @Test("confirming merges whole-word rules")
    func confirm() async throws {
        let model = makeModel()
        model.findReplaceRules = []
        let url = try write("cat,dog", named: "list.csv")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        await model.importRulesFile(from: url)
        model.confirmRuleImport()

        #expect(model.pendingRuleImport == nil)
        #expect(model.findReplaceRules.map(\.find) == ["cat"])
        #expect(model.findReplaceRules.first?.wholeWord == true)
    }

    @Test("cancelling leaves the rules unchanged")
    func cancel() async throws {
        let model = makeModel()
        model.findReplaceRules = []
        let url = try write("cat,dog", named: "list.csv")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        await model.importRulesFile(from: url)
        model.cancelRuleImport()

        #expect(model.pendingRuleImport == nil)
        #expect(model.findReplaceRules.isEmpty)
    }

    @Test("a JSON pack merges straight away, without a preview")
    func jsonUnchanged() async throws {
        let model = makeModel()
        model.findReplaceRules = []
        let pack = TermPack(name: "T", locale: "en", rules: [TermPackRule(find: "redis", replace: "Redis")])
        let url = try write(String(decoding: try TermPackIO.encode(pack), as: UTF8.self), named: "pack.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        await model.importRulesFile(from: url)

        #expect(model.pendingRuleImport == nil)
        #expect(model.findReplaceRules.map(\.find) == ["redis"])
    }

    @Test("a file that isn't UTF-8 fails the import")
    func notUTF8() async throws {
        let model = makeModel()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RuleList-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("list.csv")
        try Data([0xFF, 0xFE, 0x61, 0x00, 0x2C, 0x00]).write(to: url)
        defer { try? FileManager.default.removeItem(at: dir) }

        await model.importRulesFile(from: url)

        #expect(model.pendingRuleImport == nil)
        if case .failed = model.phase {} else { Issue.record("expected a failed phase") }
    }

    @Test("regex and whole words exclude each other in the editor")
    func exclusivity() {
        var rule = FindReplaceRule(find: "a", replace: "b")
        rule.setRegex(true)
        rule.setWholeWord(true)
        #expect(rule.wholeWord && !rule.regex)
        rule.setRegex(true)
        #expect(rule.regex && !rule.wholeWord)
        rule.setRegex(false)
        #expect(!rule.regex && !rule.wholeWord)
    }
}
