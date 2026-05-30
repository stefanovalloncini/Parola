import Foundation
import Testing
@testable import Parola

@Suite("FileCopier")
struct FileCopierTests {
    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-filecopier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("copy writes the source bytes to the destination")
    func copyWritesBytes() async throws {
        let dir = try scratchDir()
        let source = dir.appendingPathComponent("source.bin")
        let destination = dir.appendingPathComponent("dest.bin")
        let payload = Data("parola payload \(UUID().uuidString)".utf8)
        try payload.write(to: source)

        try await FileCopier.copy(from: source, to: destination)

        #expect(FileManager.default.fileExists(atPath: destination.path))
        let copied = try Data(contentsOf: destination)
        #expect(copied == payload)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("copying a missing source throws")
    func missingSourceThrows() async throws {
        let dir = try scratchDir()
        let source = dir.appendingPathComponent("does-not-exist.bin")
        let destination = dir.appendingPathComponent("dest.bin")

        await #expect(throws: (any Error).self) {
            try await FileCopier.copy(from: source, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("copying onto an existing destination throws and leaves it intact")
    func existingDestinationThrows() async throws {
        let dir = try scratchDir()
        let source = dir.appendingPathComponent("source.bin")
        let destination = dir.appendingPathComponent("dest.bin")
        try Data("new".utf8).write(to: source)
        let original = Data("original".utf8)
        try original.write(to: destination)

        await #expect(throws: (any Error).self) {
            try await FileCopier.copy(from: source, to: destination)
        }
        let unchanged = try Data(contentsOf: destination)
        #expect(unchanged == original)
    }
}
