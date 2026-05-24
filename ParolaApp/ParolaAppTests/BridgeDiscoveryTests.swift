import Foundation
import Testing
@testable import Parola

@Suite("BridgeDiscovery")
struct BridgeDiscoveryTests {

    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-bridge-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("write produces bridge.json at the chosen cacheDir with mode 0600")
    func writeProducesFileWithRestrictivePermissions() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let discovery = BridgeDiscovery(cacheDir: dir)

        try discovery.write(
            port: 58213,
            token: "token-abc",
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            startedAt: Date(),
            serverVersion: 2
        )

        #expect(FileManager.default.fileExists(atPath: discovery.fileURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: discovery.fileURL.path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600)
    }

    @Test("read returns the record when the PID matches a live process")
    func readReturnsRecordForLivePID() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let discovery = BridgeDiscovery(cacheDir: dir)
        let livePID = Int(ProcessInfo.processInfo.processIdentifier)

        try discovery.write(
            port: 58213,
            token: "token-abc",
            pid: livePID,
            startedAt: Date(),
            serverVersion: 2
        )

        let record = discovery.read()
        #expect(record != nil)
        #expect(record?.port == 58213)
        #expect(record?.token == "token-abc")
        #expect(record?.pid == livePID)
        #expect(record?.serverVersion == 2)
    }

    @Test("read returns nil when the recorded PID does not refer to a live process")
    func readReturnsNilForBogusPID() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let discovery = BridgeDiscovery(cacheDir: dir)

        try discovery.write(
            port: 58213,
            token: "token-abc",
            pid: 99_999_999,
            startedAt: Date(),
            serverVersion: 2
        )

        #expect(discovery.read() == nil)
    }

    @Test("read returns nil when no file exists")
    func readReturnsNilWhenMissing() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let discovery = BridgeDiscovery(cacheDir: dir)
        #expect(discovery.read() == nil)
    }

    @Test("remove deletes the bridge.json file")
    func removeDeletesFile() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let discovery = BridgeDiscovery(cacheDir: dir)

        try discovery.write(
            port: 58213,
            token: "token-abc",
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            startedAt: Date(),
            serverVersion: 2
        )
        #expect(FileManager.default.fileExists(atPath: discovery.fileURL.path))

        discovery.remove()
        #expect(FileManager.default.fileExists(atPath: discovery.fileURL.path) == false)
    }
}
