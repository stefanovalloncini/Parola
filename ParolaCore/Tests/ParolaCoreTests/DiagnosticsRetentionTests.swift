import Foundation
import Testing
@testable import ParolaCore

@Suite("Diagnostics retention", .serialized)
struct DiagnosticsRetentionTests {
    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-ret-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFile(_ dir: URL, _ name: String, bytes: Int, ageDays: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        let date = Date().addingTimeInterval(-Double(ageDays) * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    @Test("files past the retention window are deleted")
    func deletesExpired() throws {
        let dir = tempDirectory()
        let old = try makeFile(dir, "parola-1-100.jsonl", bytes: 10, ageDays: 9)
        let fresh = try makeFile(dir, "parola-2-200.jsonl", bytes: 10, ageDays: 1)
        let sink = FileDiagnosticsSink(directory: dir, retentionDays: 7)
        sink.sweep(now: Date())
        #expect(FileManager.default.fileExists(atPath: old.path) == false)
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test("oldest files are dropped first when over the byte budget")
    func trimsToBudgetOldestFirst() throws {
        let dir = tempDirectory()
        let oldest = try makeFile(dir, "parola-1-100.jsonl", bytes: 600, ageDays: 3)
        let middle = try makeFile(dir, "parola-2-200.jsonl", bytes: 600, ageDays: 2)
        let newest = try makeFile(dir, "parola-3-300.jsonl", bytes: 600, ageDays: 1)
        let sink = FileDiagnosticsSink(directory: dir, retentionDays: 7, totalBudgetBytes: 1_400)
        sink.sweep(now: Date())
        #expect(FileManager.default.fileExists(atPath: oldest.path) == false)
        #expect(FileManager.default.fileExists(atPath: middle.path))
        #expect(FileManager.default.fileExists(atPath: newest.path))
    }

    @Test("unrelated files in the directory are left alone")
    func ignoresForeignFiles() throws {
        let dir = tempDirectory()
        let foreign = try makeFile(dir, "automation-audit-1-100.jsonl", bytes: 10, ageDays: 30)
        let sink = FileDiagnosticsSink(directory: dir, retentionDays: 7)
        sink.sweep(now: Date())
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }
}
