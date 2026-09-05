import Foundation
import Testing
@testable import Parola

@Suite("AutomationAuditLog")
struct AutomationAuditLogTests {

    /// Above PID_MAX, so no process can ever own a file named after it.
    private static let deadPID = 999_999

    private func scratchDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomationAuditLogTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeFile(_ dir: URL, _ name: String, bytes: Int, ageDays: Int) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        let date = Date().addingTimeInterval(-Double(ageDays) * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    private func readLines(in directory: URL) throws -> [[String: Any]] {
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".jsonl") }
            .sorted()
        var out: [[String: Any]] = []
        for file in files {
            let data = try Data(contentsOf: directory.appendingPathComponent(file))
            let text = try #require(String(data: data, encoding: .utf8))
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
                out.append(try #require(object as? [String: Any]))
            }
        }
        return out
    }

    @Test("records a single JSONL line with the core fields")
    func recordsOneLine() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationAuditLog(cacheDir: dir)

        await log.record(
            id: "req-1",
            command: "get_state",
            args: AutomationArgs(["limit": .int(5)]),
            ok: true,
            elapsedMs: 12
        )

        let lines = try readLines(in: dir)
        #expect(lines.count == 1)
        let entry = try #require(lines.first)
        #expect(entry["id"] as? String == "req-1")
        #expect(entry["cmd"] as? String == "get_state")
        #expect(entry["ok"] as? Bool == true)
        #expect(entry["elapsedMs"] as? Int == 12)
        #expect(entry["ts"] is String)
        let args = try #require(entry["args"] as? [String: Any])
        #expect(args["limit"] as? Int == 5)
    }

    @Test("omits errorCode on success and includes it on failure")
    func errorCodePresence() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationAuditLog(cacheDir: dir)

        await log.record(id: "ok", command: "ping", args: AutomationArgs(), ok: true, elapsedMs: 1)
        await log.record(
            id: "bad",
            command: "ping",
            args: AutomationArgs(),
            ok: false,
            elapsedMs: 2,
            errorCode: "PRECONDITION"
        )

        let lines = try readLines(in: dir)
        #expect(lines.count == 2)
        let success = try #require(lines.first { $0["id"] as? String == "ok" })
        let failure = try #require(lines.first { $0["id"] as? String == "bad" })
        #expect(success["errorCode"] == nil)
        #expect(failure["errorCode"] as? String == "PRECONDITION")
    }

    @Test("appends successive records as separate JSONL lines")
    func appendsMultipleLines() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationAuditLog(cacheDir: dir)

        for index in 0..<5 {
            await log.record(
                id: "req-\(index)",
                command: "noop",
                args: AutomationArgs(),
                ok: true,
                elapsedMs: index
            )
        }

        let lines = try readLines(in: dir)
        #expect(lines.count == 5)
        #expect(lines.map { $0["id"] as? String } == ["req-0", "req-1", "req-2", "req-3", "req-4"])
    }

    @Test("serializes nested args through AutomationValue")
    func serializesNestedArgs() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationAuditLog(cacheDir: dir)

        await log.record(
            id: "nested",
            command: "start_batch",
            args: AutomationArgs([
                "files": .array([.string("a.wav"), .string("b.wav")]),
                "options": .object(["timestamps": .bool(true)]),
            ]),
            ok: true,
            elapsedMs: 0
        )

        let entry = try #require(try readLines(in: dir).first)
        let args = try #require(entry["args"] as? [String: Any])
        #expect(args["files"] as? [String] == ["a.wav", "b.wav"])
        let options = try #require(args["options"] as? [String: Any])
        #expect(options["timestamps"] as? Bool == true)
    }

    @Test("files past the retention window are deleted")
    func sweepDeletesExpired() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = try makeFile(dir, "automation-audit-\(Self.deadPID)-100.jsonl", bytes: 10, ageDays: 9)
        let fresh = try makeFile(dir, "automation-audit-\(Self.deadPID)-200.jsonl", bytes: 10, ageDays: 1)
        let log = AutomationAuditLog(cacheDir: dir, retentionDays: 7)

        let outcome = await log.sweep(now: Date())

        #expect(outcome.deleted == 1)
        #expect(FileManager.default.fileExists(atPath: old.path) == false)
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test("oldest files are dropped first when over the byte budget")
    func sweepTrimsToBudgetOldestFirst() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldest = try makeFile(dir, "automation-audit-\(Self.deadPID)-100.jsonl", bytes: 600, ageDays: 3)
        let middle = try makeFile(dir, "automation-audit-\(Self.deadPID)-200.jsonl", bytes: 600, ageDays: 2)
        let newest = try makeFile(dir, "automation-audit-\(Self.deadPID)-300.jsonl", bytes: 600, ageDays: 1)
        let log = AutomationAuditLog(cacheDir: dir, retentionDays: 7, totalBudgetBytes: 1_400)

        let outcome = await log.sweep(now: Date())

        #expect(outcome.deleted == 1)
        #expect(outcome.overBudget == false)
        #expect(outcome.bytesRemaining == 1_200)
        #expect(FileManager.default.fileExists(atPath: oldest.path) == false)
        #expect(FileManager.default.fileExists(atPath: middle.path))
        #expect(FileManager.default.fileExists(atPath: newest.path))
    }

    @Test("diagnostics files sharing the directory are left alone")
    func sweepIgnoresForeignFiles() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let foreign = try makeFile(dir, "parola-1-100.jsonl", bytes: 4_000, ageDays: 30)
        let log = AutomationAuditLog(cacheDir: dir, retentionDays: 7, totalBudgetBytes: 100)

        let outcome = await log.sweep(now: Date())

        #expect(outcome.deleted == 0)
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test("the budget trim spares a file a live sibling process is still writing")
    func sweepSparesLiveSibling() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let livePID = ProcessInfo.processInfo.processIdentifier
        let sibling = try makeFile(dir, "automation-audit-\(livePID)-100.jsonl", bytes: 600, ageDays: 3)
        let orphan = try makeFile(dir, "automation-audit-\(Self.deadPID)-200.jsonl", bytes: 600, ageDays: 2)
        let log = AutomationAuditLog(cacheDir: dir, retentionDays: 7, totalBudgetBytes: 700)

        let outcome = await log.sweep(now: Date())

        #expect(outcome.skippedLive == 1)
        #expect(
            FileManager.default.fileExists(atPath: sibling.path),
            "deleting a live process's open log unlinks the inode it keeps writing to"
        )
        #expect(FileManager.default.fileExists(atPath: orphan.path) == false)
    }

    @Test("the file this process is writing survives both the age cutoff and the budget trim")
    func sweepSparesOwnFile() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationAuditLog(cacheDir: dir, retentionDays: 7, totalBudgetBytes: 100)
        await log.record(id: "x", command: "noop", args: AutomationArgs(), ok: true, elapsedMs: 0)
        let own = await log.currentFileURL()
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30 * 86_400)],
            ofItemAtPath: own.path
        )

        let outcome = await log.sweep(now: Date())

        #expect(outcome.deleted == 0)
        #expect(FileManager.default.fileExists(atPath: own.path))
    }

    @Test("the budget trim reclaims this process's own closed rotations")
    func sweepTrimsOwnClosedRotations() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationAuditLog(cacheDir: dir, retentionDays: 7, totalBudgetBytes: 1_000)
        await log.record(id: "x", command: "noop", args: AutomationArgs(), ok: true, elapsedMs: 0)
        let open = await log.currentFileURL()
        let base = open.deletingPathExtension().lastPathComponent
        var rotations: [URL] = []
        for index in 1...5 {
            rotations.append(try makeFile(dir, "\(base)-\(index).jsonl", bytes: 600, ageDays: 6 - index))
        }

        let outcome = await log.sweep(now: Date())

        #expect(outcome.deleted == 4)
        #expect(outcome.skippedLive == 0)
        #expect(outcome.overBudget == false)
        #expect(FileManager.default.fileExists(atPath: open.path))
        for url in rotations.dropLast() {
            #expect(FileManager.default.fileExists(atPath: url.path) == false)
        }
        #expect(FileManager.default.fileExists(atPath: rotations[4].path))
    }

    @Test("rotating past the threshold sweeps expired files")
    func rotationSweeps() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let expired = try makeFile(dir, "automation-audit-\(Self.deadPID)-100.jsonl", bytes: 10, ageDays: 9)
        let log = AutomationAuditLog(cacheDir: dir, retentionDays: 7, totalBudgetBytes: 10_000, rotateThreshold: 200)
        let first = await log.currentFileURL()

        for index in 0..<4 {
            await log.record(id: "\(index)", command: "noop", args: AutomationArgs(), ok: true, elapsedMs: 0)
        }

        let current = await log.currentFileURL()
        #expect(current != first, "four records exceed a 200-byte threshold and rotate")
        #expect(FileManager.default.fileExists(atPath: expired.path) == false)
    }

    @Test("writes into the supplied cache directory, creating it on demand")
    func createsCacheDirectory() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FileManager.default.fileExists(atPath: dir.path) == false)

        let log = AutomationAuditLog(cacheDir: dir)
        await log.record(id: "x", command: "noop", args: AutomationArgs(), ok: true, elapsedMs: 0)

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.contains { $0.hasSuffix(".jsonl") })
    }
}
