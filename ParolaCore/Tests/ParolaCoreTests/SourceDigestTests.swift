import Testing
import Foundation
@testable import ParolaCore

@Suite("SourceDigest", .tags(.fileSystem))
struct SourceDigestTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-digest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("hashes the bytes, not the name")
    func knownVector() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("a.wav")
        let second = dir.appendingPathComponent("b.m4a")
        try Data("abc".utf8).write(to: first)
        try Data("abc".utf8).write(to: second)

        let digest = try SourceDigest.compute(contentsOf: first)
        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(try SourceDigest.compute(contentsOf: second) == digest)
    }

    @Test("an empty file still hashes")
    func emptyFile() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("empty.wav")
        try Data().write(to: url)
        #expect(try SourceDigest.compute(contentsOf: url)
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("a file larger than one chunk hashes the whole thing")
    func multipleChunks() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let head = dir.appendingPathComponent("head.wav")
        let full = dir.appendingPathComponent("full.wav")
        let block = Data(repeating: 0x41, count: SourceDigest.chunkBytes)
        try block.write(to: head)
        try (block + Data(repeating: 0x42, count: 32)).write(to: full)

        #expect(try SourceDigest.compute(contentsOf: head) != SourceDigest.compute(contentsOf: full))
    }

    @Test("a cancelled hash returns nothing")
    func cancellation() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("big.wav")
        try Data(repeating: 0x41, count: SourceDigest.chunkBytes * 3).write(to: url)

        #expect(try SourceDigest.compute(contentsOf: url, isCancelled: { true }) == nil)
    }

    @Test("a missing file throws")
    func missingFile() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: (any Error).self) {
            try SourceDigest.compute(contentsOf: dir.appendingPathComponent("gone.wav"))
        }
    }

    @Test("the async front door reports nothing rather than throwing")
    func asyncMissingFile() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await SourceDigest.digest(of: dir.appendingPathComponent("gone.wav")) == nil)
    }

    @Test("the async front door matches the synchronous hash")
    func asyncMatchesSync() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.wav")
        try Data("RIFFhello".utf8).write(to: url)
        #expect(await SourceDigest.digest(of: url) == (try SourceDigest.compute(contentsOf: url)))
    }
}
