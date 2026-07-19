import Foundation
import Testing
@testable import ParolaMCP

@Suite("BridgeClient stale discovery")
struct BridgeClientDiscoveryTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-bridge-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func deadPID() throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return Int(process.processIdentifier)
    }

    private func writeDiscovery(pid: Int, in dir: URL) throws {
        let record: [String: Any] = ["pid": pid, "port": 1, "token": "x", "serverVersion": 2]
        let data = try JSONSerialization.data(withJSONObject: record)
        try data.write(to: dir.appendingPathComponent("bridge.json"))
    }

    @Test("a dead instance's record produces a dead-instance hint")
    func deadInstanceHint() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeDiscovery(pid: try deadPID(), in: dir)

        let hint = BridgeClient.staleDiscoveryHint(discoveryFileURL: dir.appendingPathComponent("bridge.json"))
        #expect(hint?.contains("dead instance") == true)
    }

    @Test("a live pid whose port refuses produces an overwritten-files hint")
    func livePIDHint() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeDiscovery(pid: Int(ProcessInfo.processInfo.processIdentifier), in: dir)

        let hint = BridgeClient.staleDiscoveryHint(discoveryFileURL: dir.appendingPathComponent("bridge.json"))
        #expect(hint?.contains("isn't accepting") == true)
    }

    @Test("no record or a malformed record produces no hint")
    func missingRecordNoHint() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(BridgeClient.staleDiscoveryHint(discoveryFileURL: dir.appendingPathComponent("bridge.json")) == nil)

        try Data("not json".utf8).write(to: dir.appendingPathComponent("bridge.json"))
        #expect(BridgeClient.staleDiscoveryHint(discoveryFileURL: dir.appendingPathComponent("bridge.json")) == nil)

        try writeDiscovery(pid: 0, in: dir)
        #expect(BridgeClient.staleDiscoveryHint(discoveryFileURL: dir.appendingPathComponent("bridge.json")) == nil)
    }

    @Test("an unreachable bridge with a dead record surfaces the hint through call()")
    func callSurfacesHint() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("1".utf8).write(to: dir.appendingPathComponent("bridge.port"))
        try writeDiscovery(pid: try deadPID(), in: dir)

        let client = BridgeClient(
            portFileURL: dir.appendingPathComponent("bridge.port"),
            tokenFileURL: dir.appendingPathComponent("bridge.token"),
            discoveryFileURL: dir.appendingPathComponent("bridge.json"),
            timeout: 5
        )
        await #expect(throws: BridgeClient.BridgeNotRunning.self) {
            _ = try await client.call("ping", argsJSON: Data())
        }
        do {
            _ = try await client.call("ping", argsJSON: Data())
        } catch let error as BridgeClient.BridgeNotRunning {
            #expect(error.errorDescription?.contains("dead instance") == true)
        }
    }
}
