import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Launches Parola.app and polls for the bridge port file. Backs the `parola_open_app` tool.
public enum AppLauncher {
    public static func launch(bundleID: String, timeoutMs: Int) async throws -> String {
        let portFile = portFileURL()

        if FileManager.default.fileExists(atPath: portFile.path) {
            return BridgeJSON.string([
                "launched": false,
                "bridgeReady": true,
                "portFile": portFile.path,
            ] as [String: Any])
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
