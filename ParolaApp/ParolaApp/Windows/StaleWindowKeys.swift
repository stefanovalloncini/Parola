import Foundation
import ParolaCore

/// Window and sidebar frames SwiftUI saved under a scene's view type, whose addresses change with every build, so no later launch reads them.
enum StaleWindowKeys {
    static let prefixes = ["NSWindow Frame SwiftUI.", "NSSplitView Subview Frames SwiftUI."]

    static func isStale(_ key: String) -> Bool {
        prefixes.contains { key.hasPrefix($0) }
    }

    /// Key by key through CFPreferences: cfprefsd drops a bulk write to a domain over its 4 MB limit, and every `UserDefaults` removal sets off an AppKit pass over the whole domain.
    @discardableResult
    static func prune(domain: String) -> Int {
        let id = domain as CFString
        let keys = CFPreferencesCopyKeyList(id, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
        let stale = keys.filter(isStale)
        for key in stale {
            CFPreferencesSetAppValue(key as CFString, nil, id)
        }
        return stale.count
    }

    static func pruneInBackground() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        Task.detached(priority: .utility) {
            let removed = prune(domain: domain)
            guard removed > 0 else { return }
            ParolaLog.info(.appLifecycle, "stale window frames removed", [.count: .int(removed)])
        }
    }
}
