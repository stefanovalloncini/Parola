import Foundation
import Testing
@testable import ParolaCore

@Suite("CLI duplicate imports", .serialized, .enabled(if: parolaBinaryURL != nil), .tags(.fileSystem))
struct CLIDuplicateProcessTests {

    private func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-cli-dupe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func seed(_ library: URL, audio: URL, model: String = "openai_whisper-tiny") async throws -> LibraryEntry {
        let store = LibraryStore(libraryURL: library, extraIndexer: nil)
        return try await store.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "seeded")],
                language: "en",
                modelName: model
            ),
            audioSource: audio,
            title: "Kickoff call"
        )
    }

    private func makeWAV(in dir: URL, named name: String) throws -> URL {
        let sampleRate: UInt32 = 16_000, frames: UInt32 = 1_600
        let dataBytes = frames * 2
        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        ascii("RIFF"); le32(36 + dataBytes); ascii("WAVE")
        ascii("fmt "); le32(16); le16(1); le16(1)
        le32(sampleRate); le32(sampleRate * 2); le16(2); le16(16)
        ascii("data"); le32(dataBytes)
        data.append(Data(count: Int(dataBytes)))
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func snapshotFiles(in library: URL) -> [String: Date] {
        let root = library.appendingPathComponent(".search-index", isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var files: [String: Date] = [:]
        for case let url as URL in walker where !url.hasDirectoryPath {
            files[url.lastPathComponent] = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        return files
    }

    @Test("the CLI reads the library it is pointed at and never writes its index")
    func cliLeavesTheIndexAlone() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let library = scratch.appendingPathComponent("library", isDirectory: true)
        let audio = try makeWAV(in: scratch, named: "kickoff.wav")
        let app = LibraryStore(libraryURL: library, extraIndexer: nil)
        _ = try await app.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "seeded")],
                language: "en",
                modelName: "openai_whisper-tiny"
            ),
            audioSource: audio,
            title: "Kickoff call"
        )
        await app.flush()
        // A bundle the snapshot lacks, with no digest or duration: a store that owned the library would
        // rewrite the index on sight, and its verify would stamp the digest into the manifest.
        let behind = try ParolaDocument.write(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "behind")],
                language: "en",
                modelName: "openai_whisper-tiny"
            ),
            audioURL: audio,
            to: library.appendingPathComponent("behind")
        )
        try ParolaDocument.updateManifest(at: behind) { manifest in
            manifest.sourceDigest = nil
            manifest.durationSeconds = nil
        }
        let behindManifest = behind.appendingPathComponent("manifest.json")
        let manifestBefore = try Data(contentsOf: behindManifest)
        let before = snapshotFiles(in: library)
        #expect(!before.isEmpty)

        let transcribe = try runParola(
            ["transcribe", audio.path, "--library", library.path, "--skip-duplicates"], timeout: 60
        )
        let stats = try runParola(["library", "stats", "--library", library.path], timeout: 60)
        let verify = try runParola(["library", "verify", "--library", library.path], timeout: 60)

        #expect(transcribe.stderr.contains("Already in the library as Kickoff call"))
        #expect(stats.stdout.contains("Transcripts: 2"))
        #expect(verify.stdout.contains("Healthy: 2"))
        #expect(snapshotFiles(in: library) == before)
        #expect(try Data(contentsOf: behindManifest) == manifestBefore)
    }

    @Test("--skip-duplicates stops before loading a model and says why")
    func skipDuplicatesReturnsEarly() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let library = scratch.appendingPathComponent("library", isDirectory: true)
        let audio = try makeWAV(in: scratch, named: "kickoff.wav")
        _ = try await seed(library, audio: audio)

        let run = try runParola([
            "transcribe", audio.path, "--library", library.path, "--skip-duplicates",
        ], timeout: 60)

        #expect(run.status == 0)
        #expect(run.stderr.contains("Already in the library as Kickoff call"))
        #expect(run.stderr.contains("); skipping"))
        #expect(!run.output.contains("Loading model"))
        #expect(run.stdout.isEmpty)
    }
}
