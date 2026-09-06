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
        let old = try makeFile(dir, "parola-\(Self.deadPID)-100.jsonl", bytes: 10, ageDays: 9)
        let fresh = try makeFile(dir, "parola-\(Self.deadPID)-200.jsonl", bytes: 10, ageDays: 1)
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

    @Test("the age cutoff spares an expired file a live process still holds open")
    func ageCutoffSparesLiveSibling() async throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir, retentionDays: 7)
        try await sink.waitForInstallSweep()
        let livePID = ProcessInfo.processInfo.processIdentifier
        let idle = try makeFile(dir, "parola-\(livePID)-100.jsonl", bytes: 10, ageDays: 9)
        let orphan = try makeFile(dir, "parola-\(Self.deadPID)-200.jsonl", bytes: 10, ageDays: 9)

        let outcome = sink.sweep(now: Date())

        #expect(
            FileManager.default.fileExists(atPath: idle.path),
            "an idle process's mtime never advances, so ageing its open file out unlinks the inode"
        )
        #expect(FileManager.default.fileExists(atPath: orphan.path) == false)
        #expect(outcome.deleted == 1)
        #expect(outcome.skippedLive == 1)
    }

    @Test("a live sibling spared by both the cutoff and the trim is counted once")
    func liveSiblingCountedOnce() throws {
        let dir = tempDirectory()
        let livePID = ProcessInfo.processInfo.processIdentifier
        _ = try makeFile(dir, "parola-\(livePID)-100.jsonl", bytes: 600, ageDays: 9)
        let sink = FileDiagnosticsSink(directory: dir, retentionDays: 7, totalBudgetBytes: 100)

        let outcome = sink.sweep(now: Date())

        #expect(outcome.skippedLive == 1)
        #expect(outcome.overBudget)
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
    func sweepReportsDeletions() async throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir, retentionDays: 7, totalBudgetBytes: 700)
        try await sink.waitForInstallSweep()
        _ = try makeFile(dir, "parola-\(Self.deadPID)-100.jsonl", bytes: 600, ageDays: 9)
        _ = try makeFile(dir, "parola-\(Self.deadPID)-200.jsonl", bytes: 600, ageDays: 3)
        _ = try makeFile(dir, "parola-\(Self.deadPID)-300.jsonl", bytes: 600, ageDays: 1)
        let outcome = sink.sweep(now: Date())
        #expect(outcome.deleted == 2, "one past the age cutoff, one to reach the budget")
        #expect(outcome.overBudget == false)
        #expect(outcome.bytesRemaining == 600)
    }

    @Test("the budget trim reclaims this sink's own closed rotations")
    func trimsOwnClosedRotations() async throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir, retentionDays: 7, totalBudgetBytes: 1_000)
        try await sink.waitForInstallSweep()
        let open = sink.currentFileURL
        try Data(repeating: 0x61, count: 100).write(to: open)
        let base = open.deletingPathExtension().lastPathComponent
        var rotations: [URL] = []
        for index in 1...5 {
            rotations.append(try makeFile(dir, "\(base)-\(index).jsonl", bytes: 600, ageDays: 6 - index))
        }

        let outcome = sink.sweep(now: Date())

        #expect(outcome.deleted == 4)
        #expect(outcome.ownRotations == 4)
        #expect(outcome.skippedLive == 0)
        #expect(outcome.overBudget == false)
        #expect(FileManager.default.fileExists(atPath: open.path))
        for url in rotations.dropLast() {
            #expect(FileManager.default.fileExists(atPath: url.path) == false)
        }
        #expect(FileManager.default.fileExists(atPath: rotations[4].path))
    }

    @Test("the age cutoff counts the rotations it reclaimed as this sink's")
    func ageCutoffCountsOwnRotations() async throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir, retentionDays: 7)
        try await sink.waitForInstallSweep()
        let base = sink.currentFileURL.deletingPathExtension().lastPathComponent
        _ = try makeFile(dir, "\(base)-1.jsonl", bytes: 10, ageDays: 9)
        _ = try makeFile(dir, "\(base)-2.jsonl", bytes: 10, ageDays: 8)
        _ = try makeFile(dir, "parola-\(Self.deadPID)-100.jsonl", bytes: 10, ageDays: 9)

        let outcome = sink.sweep(now: Date())

        #expect(outcome.deleted == 3)
        #expect(outcome.ownRotations == 2)
    }

    @Test("a rotation inside one sweep spares the file it made the open one")
    func rotationInsideASweepSparesTheNewOpenFile() async throws {
        let dir = tempDirectory()
        let sink = FileDiagnosticsSink(directory: dir, retentionDays: 7, totalBudgetBytes: 100)
        try await sink.waitForInstallSweep()
        let base = sink.currentFileURL.deletingPathExtension().lastPathComponent
        try Data(repeating: 0x61, count: 600).write(to: sink.currentFileURL)
        let next = try makeFile(dir, "\(base)-1.jsonl", bytes: 600, ageDays: 9)

        var rotations = 0
        let outcome = sink.sweep(now: Date()) {
            guard rotations == 0 else { return }
            rotations += 1
            sink.rotateSynchronously()
        }

        #expect(rotations == 1)
        #expect(
            FileManager.default.fileExists(atPath: next.path),
            "the sweep unlinked the file the rotation had just made the open one"
        )
        #expect(outcome.ownRotations == 1, "the file the rotation closed is the one it may reclaim")
    }

    @Test("a sink's trim spares the file another sink in this process holds open")
    func sparesASiblingSinksOpenFile() async throws {
        let dir = tempDirectory()
        let sibling = FileDiagnosticsSink(directory: dir, retentionDays: 7, totalBudgetBytes: 100)
        try await sibling.waitForInstallSweep()
        try Data(repeating: 0x61, count: 600).write(to: sibling.currentFileURL)
        let sink = FileDiagnosticsSink(directory: dir, retentionDays: 7, totalBudgetBytes: 100)
        try await sink.waitForInstallSweep()

        let outcome = sink.sweep(now: Date())

        #expect(FileManager.default.fileExists(atPath: sibling.currentFileURL.path))
        #expect(outcome.skippedLive == 1)
    }

    @Test("the over-budget notice reports the sink's own rotations next to the live skips")
    func overBudgetNoticeCountsOwnRotations() async throws {
        let dir = tempDirectory()
        let capture = CapturingDiagnosticsSink()
        ParolaLog.install(capture)
        defer { ParolaLog.uninstall() }
        let sink = FileDiagnosticsSink(
            directory: dir, maxFileBytes: 100, retentionDays: 7, totalBudgetBytes: 100
        )
        try await sink.waitForInstallSweep()
        let livePID = ProcessInfo.processInfo.processIdentifier
        _ = try makeFile(dir, "parola-\(livePID)-100.jsonl", bytes: 600, ageDays: 3)

        sink.enqueue(LogRecord(
            timestamp: Date(), level: .notice, subsystem: .core, category: .diagnostics,
            message: "rotate me", fields: [:], file: "T.swift", line: 1
        ))
        await sink.flush()

        let notice = try #require(await overBudgetNotice(in: capture))
        #expect(notice.fields[.count]?.text == "1")
        #expect(notice.fields[.rotations]?.text == "1")
    }

    private func overBudgetNotice(
        in capture: CapturingDiagnosticsSink,
        timeout: Duration = .seconds(10)
    ) async -> LogRecord? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let found = capture.records.first {
                $0.message.rendered == "diagnostics sweep finished over budget"
            }
            if let found { return found }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
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
