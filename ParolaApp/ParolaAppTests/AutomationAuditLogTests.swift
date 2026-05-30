import Foundation
import Testing
@testable import Parola

@Suite("AutomationAuditLog")
struct AutomationAuditLogTests {

    private func scratchDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomationAuditLogTests-\(UUID().uuidString)", isDirectory: true)
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
