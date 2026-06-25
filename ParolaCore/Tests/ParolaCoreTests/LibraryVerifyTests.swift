import Testing
import Foundation
@testable import ParolaCore

@Suite("LibraryStore.verify", .tags(.fileSystem))
struct LibraryVerifyTests {
    private func makeLibrary() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-verify-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @discardableResult
    private func writeHealthy(in library: URL, named name: String) throws -> URL {
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 0.5, text: "hi")],
            language: "en",
            modelName: "tiny"
        )
        return try ParolaDocument.write(
            transcript: transcript,
            audioURL: nil,
            to: library.appendingPathComponent(name)
        )
    }

    private func verify(_ library: URL) async -> LibraryStore.VerificationReport {
        await LibraryStore(libraryURL: library, extraIndexer: nil).verify()
    }

    @Test("a well-formed bundle is healthy with no problems")
    func healthyBundle() async throws {
        let lib = try makeLibrary()
        try writeHealthy(in: lib, named: "good")
        let report = await verify(lib)
        #expect(report.healthy.count == 1)
        #expect(report.healthy.first?.id == "good")
        #expect(report.problems.isEmpty)
    }

    @Test("a bundle missing manifest.json is flagged")
    func missingManifest() async throws {
        let lib = try makeLibrary()
        let bundle = try writeHealthy(in: lib, named: "broken")
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("manifest.json"))
        let report = await verify(lib)
        #expect(report.healthy.isEmpty)
        #expect(report.problems.count == 1)
        #expect(report.problems.first?.issue == .missingManifest)
    }

    @Test("a manifest that isn't valid JSON is flagged unreadable")
    func unreadableManifest() async throws {
        let lib = try makeLibrary()
        let bundle = try writeHealthy(in: lib, named: "broken")
        try Data("{ not json ]]".utf8).write(to: bundle.appendingPathComponent("manifest.json"))
        let report = await verify(lib)
        #expect(report.healthy.isEmpty)
        #expect(report.problems.first?.issue == .unreadableManifest)
    }

    @Test("valid JSON with the wrong shape is flagged unreadable")
    func wrongShapeManifest() async throws {
        let lib = try makeLibrary()
        let bundle = try writeHealthy(in: lib, named: "broken")
        try Data(#"{"foo":"bar","version":1}"#.utf8).write(to: bundle.appendingPathComponent("manifest.json"))
        let report = await verify(lib)
        #expect(report.healthy.isEmpty)
        #expect(report.problems.first?.issue == .unreadableManifest)
    }

    @Test("a manifest version newer than this app is flagged")
    func versionTooNew() async throws {
        let lib = try makeLibrary()
        let bundle = try writeHealthy(in: lib, named: "future")
        let manifestURL = bundle.appendingPathComponent("manifest.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(ParolaDocument.Manifest.self, from: Data(contentsOf: manifestURL))
        let bumped = ParolaDocument.Manifest.currentVersion + 99
        manifest.version = bumped
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL)
        let report = await verify(lib)
        #expect(report.healthy.isEmpty)
        #expect(report.problems.first?.issue == .versionTooNew(bumped))
    }

    @Test("a bundle missing transcript.json is flagged")
    func missingTranscript() async throws {
        let lib = try makeLibrary()
        let bundle = try writeHealthy(in: lib, named: "broken")
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("transcript.json"))
        let report = await verify(lib)
        #expect(report.healthy.isEmpty)
        #expect(report.problems.first?.issue == .missingTranscript)
    }

    @Test("non-.parola entries are ignored")
    func ignoresNonBundles() async throws {
        let lib = try makeLibrary()
        try writeHealthy(in: lib, named: "good")
        try Data("stray".utf8).write(to: lib.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(
            at: lib.appendingPathComponent("subdir", isDirectory: true),
            withIntermediateDirectories: true
        )
        let report = await verify(lib)
        #expect(report.healthy.count == 1)
        #expect(report.problems.isEmpty)
    }

    @Test("an empty library has no healthy entries and no problems")
    func emptyLibrary() async throws {
        let lib = try makeLibrary()
        let report = await verify(lib)
        #expect(report.healthy.isEmpty)
        #expect(report.problems.isEmpty)
    }

    @Test("a mixed library reports the healthy one and every problem")
    func mixedLibrary() async throws {
        let lib = try makeLibrary()
        try writeHealthy(in: lib, named: "good")
        let noManifest = try writeHealthy(in: lib, named: "no-manifest")
        try FileManager.default.removeItem(at: noManifest.appendingPathComponent("manifest.json"))
        let noTranscript = try writeHealthy(in: lib, named: "no-transcript")
        try FileManager.default.removeItem(at: noTranscript.appendingPathComponent("transcript.json"))
        let report = await verify(lib)
        #expect(report.healthy.count == 1)
        #expect(report.healthy.first?.id == "good")
        #expect(report.problems.count == 2)
        let issues = report.problems.map(\.issue)
        #expect(issues.contains(.missingManifest))
        #expect(issues.contains(.missingTranscript))
    }
}
