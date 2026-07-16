import Darwin
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Launches Parola.app and polls for the bridge port file. Backs the `parola_open_app` tool.
public enum AppLauncher {
    public static func launch(bundleID: String, timeoutMs: Int) async throws -> String {
        let portFile = portFileURL()

        if FileManager.default.fileExists(atPath: portFile.path) {
            if bridgeListening(portFile: portFile) {
                return BridgeJSON.string([
                    "launched": false,
                    "bridgeReady": true,
                    "portFile": portFile.path,
                ] as [String: Any])
            }
            // A crash or force-quit leaves the port file behind; a stale file must not
            // short-circuit the launch this tool exists to perform.
            try? FileManager.default.removeItem(at: portFile)
        }

        #if canImport(AppKit)
        let appURL = await MainActor.run { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
        guard let appURL else {
            throw MCPToolError("App not found: \(bundleID). Install Parola.app or pass a different bundleID.")
        }
        try await openApplication(at: appURL)
        #else
        throw MCPToolError("Launching Parola.app requires macOS.")
        #endif

        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: portFile.path) {
                return BridgeJSON.string([
                    "launched": true,
                    "bridgeReady": true,
                    "portFile": portFile.path,
                ] as [String: Any])
            }
            try await Task.sleep(for: .milliseconds(200), clock: ContinuousClock())
        }
        return BridgeJSON.string([
            "launched": true,
            "bridgeReady": false,
            "portFile": portFile.path,
            "hint": "App launched but bridge port file didn't appear. Open the running app and confirm the bridge is enabled (Debug builds expose it by default).",
        ] as [String: Any])
    }

    #if canImport(AppKit)
    @MainActor
    private static func openApplication(at appURL: URL) async throws {
        try await NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
    #endif

    private static func bridgeListening(portFile: URL) -> Bool {
        guard let raw = try? String(contentsOf: portFile, encoding: .utf8),
              let port = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    public static func portFileURL() -> URL {
        cacheDirectory().appendingPathComponent("bridge.port")
    }

    public static func tokenFileURL() -> URL {
        cacheDirectory().appendingPathComponent("bridge.token")
    }

    private static func cacheDirectory() -> URL {
        let caches = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("Parola", isDirectory: true)
    }
}
