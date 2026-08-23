import Foundation
import Testing
@testable import ParolaCore

@Suite("Diagnostics retention", .serialized, .logFacade)
struct DiagnosticsRetentionTests {
    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-ret-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Above PID_MAX, so no process can ever own a file named after it.
    private static let deadPID = 999_999

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
        let oldest = try makeFile(dir, "parola-\(Self.deadPID)-100.jsonl", bytes: 600, ageDays: 3)
        let middle = try makeFile(dir, "parola-\(Self.deadPID)-200.jsonl", bytes: 600, ageDays: 2)
        let newest = try makeFile(dir, "parola-\(Self.deadPID)-300.jsonl", bytes: 600, ageDays: 1)
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

    @Test("the budget trim spares a file a live sibling process is still writing")
    func budgetTrimSparesLiveSibling() throws {
        let dir = tempDirectory()
        let livePID = ProcessInfo.processInfo.processIdentifier
        let sibling = try makeFile(dir, "parola-\(livePID)-100.jsonl", bytes: 600, ageDays: 3)
        let orphan = try makeFile(dir, "parola-\(Self.deadPID)-200.jsonl", bytes: 600, ageDays: 2)
        let sink = FileDiagnosticsSink(directory: dir, retentionDays: 7, totalBudgetBytes: 700)
        sink.sweep(now: Date())
        #expect(
            FileManager.default.fileExists(atPath: sibling.path),
            "deleting a live process's open log unlinks the inode it keeps writing to"
        )
        #expect(FileManager.default.fileExists(atPath: orphan.path) == false)
    }

    @Test("the age cutoff deletes an expired file even when its pid is live again")
    func expiredFileIsDeletedRegardlessOfLiveness() throws {
        let dir = tempDirectory()
        let livePID = ProcessInfo.processInfo.processIdentifier
        let expired = try makeFile(dir, "parola-\(livePID)-100.jsonl", bytes: 10, ageDays: 9)
        let sink = FileDiagnosticsSink(directory: dir, retentionDays: 7)
        sink.sweep(now: Date())
        #expect(FileManager.default.fileExists(atPath: expired.path) == false)
    }

    @Test("a sweep that cannot get under budget says so")
    func sweepReportsStillOverBudget() throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir, retentionDays: 7, totalBudgetBytes: 100)
        try Data(repeating: 0x61, count: 5_000).write(to: sink.currentFileURL)
        let livePID = ProcessInfo.processInfo.processIdentifier
        _ = try makeFile(dir, "parola-\(livePID)-100.jsonl", bytes: 600, ageDays: 3)
        let outcome = sink.sweep(now: Date())
        #expect(outcome.overBudget)
        #expect(outcome.bytesRemaining == 5_600)
        #expect(outcome.skippedLive == 1)
        #expect(outcome.deleted == 0)
    }

    @Test("a sweep that gets under budget reports what it deleted")
    func sweepReportsDeletions() throws {
        let dir = tempDirectory()
        _ = try makeFile(dir, "parola-\(Self.deadPID)-100.jsonl", bytes: 600, ageDays: 9)
        _ = try makeFile(dir, "parola-\(Self.deadPID)-200.jsonl", bytes: 600, ageDays: 3)
        _ = try makeFile(dir, "parola-\(Self.deadPID)-300.jsonl", bytes: 600, ageDays: 1)
        let sink = FileDiagnosticsSink(directory: dir, retentionDays: 7, totalBudgetBytes: 700)
        let outcome = sink.sweep(now: Date())
        #expect(outcome.deleted == 2, "one past the age cutoff, one to reach the budget")
        #expect(outcome.overBudget == false)
        #expect(outcome.bytesRemaining == 600)
    }

    @Test("the active file survives both the age cutoff and the budget trim")
    func activeFileSurvives() throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir, retentionDays: 7, totalBudgetBytes: 100)
        let active = sink.currentFileURL
        try Data(repeating: 0x61, count: 5_000).write(to: active)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30 * 86_400)],
            ofItemAtPath: active.path
        )
        sink.sweep(now: Date())
        #expect(FileManager.default.fileExists(atPath: active.path))
    }
}
