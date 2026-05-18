import AppKit
import Foundation

@MainActor
final class BrowserURLResolver {
    static let shared = BrowserURLResolver()

    private struct CacheEntry {
        let url: URL?
        let expires: Date
    }

    private let cacheLifetime: TimeInterval = 0.5
    private var cache: [String: CacheEntry] = [:]

    func currentURL(for bundleID: String) -> URL? {
        guard let script = Self.scriptSource(for: bundleID) else { return nil }
        if let cached = cache[bundleID], cached.expires > Date() {
            return cached.url
        }
        guard Self.isRunning(bundleID: bundleID) else {
            cache[bundleID] = CacheEntry(url: nil, expires: Date().addingTimeInterval(cacheLifetime))
            return nil
        }
        let raw = Self.runAppleScript(script)
        let url = raw.flatMap { URL(string: $0) }
        cache[bundleID] = CacheEntry(url: url, expires: Date().addingTimeInterval(cacheLifetime))
        return url
    }

    func invalidate() {
        cache.removeAll(keepingCapacity: true)
    }

    private static func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    private static func scriptSource(for bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Safari":
            return #"tell application "Safari" to get URL of current tab of front window"#
        case "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac":
            let appName = chromiumAppName(for: bundleID)
            return "tell application \"\(appName)\" to get URL of active tab of front window"
        case "company.thebrowser.Browser":
            return #"tell application "Arc" to get URL of active tab of front window"#
        case "org.mozilla.firefox":
            return #"tell application "Firefox" to get «class URL» of front window"#
        default:
            return nil
        }
    }

    private static func chromiumAppName(for bundleID: String) -> String {
        switch bundleID {
        case "com.google.Chrome": return "Google Chrome"
        case "com.google.Chrome.canary": return "Google Chrome Canary"
        case "com.brave.Browser": return "Brave Browser"
        case "com.microsoft.edgemac": return "Microsoft Edge"
        default: return "Google Chrome"
        }
    }

    private static func runAppleScript(_ source: String) -> String? {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let descriptor = script.executeAndReturnError(&errorInfo)
        if errorInfo != nil { return nil }
        let trimmed = descriptor.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
