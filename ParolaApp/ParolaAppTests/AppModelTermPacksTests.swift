import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("AppModel term packs")
struct AppModelTermPacksTests {

    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: UserDefaults(suiteName: "test-\(UUID())")!, libraryURL: makeTempLibraryURL("termpacks"))
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
    func importMergesRules() throws {
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

        model.importTermPack(from: url)

        let allEnabled = model.findReplaceRules.allSatisfy { $0.enabled }
        #expect(model.findReplaceRules.map(\.find) == ["kubernetes", "postgres"])
        #expect(allEnabled)
        #expect(model.phase != .failed(message: ""))
    }

    @Test("importing a term pack skips rules already present")
    func importDeduplicates() throws {
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

        model.importTermPack(from: url)

        #expect(model.findReplaceRules.map(\.find) == ["swift", "xcode"])
    }

    @Test("importing a pack with empty finds drops those rules")
    func importDropsEmptyFinds() throws {
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

        model.importTermPack(from: url)

        #expect(model.findReplaceRules.map(\.find) == ["redis"])
    }

    @Test("importing from a missing file reports a failure")
    func importMissingFileFails() {
        let model = makeModel()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")

        model.importTermPack(from: missing)

        guard case .failed(let message) = model.phase else {
            Issue.record("expected a failed phase, got \(model.phase)")
            return
        }
        #expect(message.contains("term pack"))
    }

    @Test("importing malformed JSON reports a failure")
    func importMalformedFails() throws {
        let model = makeModel()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermPackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("bad.json")
        try Data("not json".utf8).write(to: url)

        model.importTermPack(from: url)

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
