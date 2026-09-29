import AppKit

/// A no-op kept because `AppDelegate`'s appearance observer still calls it — the Dock always shows the brand art now.
@MainActor
enum DockIcon {
    static func refresh() {}
}
