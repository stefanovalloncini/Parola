import AppKit
import SwiftUI

/// Where a source app's bundle ID meets the machine it is installed on.
enum SourceAppIcon {
    static func appURL(forBundleID id: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    /// The first of `ids` that is installed, in sorted order so two installs of one vendor resolve the same way every time.
    static func installedBundleID(among ids: Set<String>) -> String? {
        ids.sorted().first { appURL(forBundleID: $0) != nil }
    }

    static func workspaceIcon(forBundleID id: String) -> NSImage? {
        appURL(forBundleID: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

/// App icons by bundle ID. A row asks for one while it draws, so the first ask only schedules the lookup and every later one reads the result.
@Observable
@MainActor
final class SourceAppIconCache {
    static let shared = SourceAppIconCache()

    private enum Lookup {
        case icon(NSImage)
        case missing
    }

    private var lookups: [String: Lookup] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private let resolve: @MainActor (String) -> NSImage?
    @ObservationIgnored private(set) var resolveCount = 0

    init(resolve: @escaping @MainActor (String) -> NSImage? = { SourceAppIcon.workspaceIcon(forBundleID: $0) }) {
        self.resolve = resolve
    }

    func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if case .icon(let image) = lookups[bundleID] { return image }
        if lookups[bundleID] == nil, requested.insert(bundleID).inserted {
            Task { @MainActor [weak self] in self?.finishLookup(of: bundleID) }
        }
        return nil
    }

    private func finishLookup(of bundleID: String) {
        resolveCount += 1
        lookups[bundleID] = resolve(bundleID).map(Lookup.icon) ?? .missing
    }
}

private struct SourceAppIconsKey: EnvironmentKey {
    static let defaultValue: SourceAppIconCache? = nil
}

extension EnvironmentValues {
    var sourceAppIcons: SourceAppIconCache? {
        get { self[SourceAppIconsKey.self] }
        set { self[SourceAppIconsKey.self] = newValue }
    }
}
