import Foundation

/// Whether the transcript inspector shows: a comfortable pane follows the preference, a narrow one hides it until asked.
enum InspectorVisibility {
    static let preferenceKey = "inspectorVisible"
    static let forcedAtNarrowWidthKey = "inspectorForcedAtNarrowWidth"

    static func isVisible(preference: Bool, forcedAtNarrowWidth: Bool, isNarrow: Bool) -> Bool {
        isNarrow ? forcedAtNarrowWidth : preference
    }

    static func toggle(in defaults: UserDefaults, isNarrow: Bool) {
        let showing = isVisible(
            preference: preference(in: defaults),
            forcedAtNarrowWidth: defaults.bool(forKey: forcedAtNarrowWidthKey),
            isNarrow: isNarrow
        )
        defaults.set(!showing, forKey: isNarrow ? forcedAtNarrowWidthKey : preferenceKey)
    }

    /// An unset key means visible, matching the pane's `@AppStorage` default.
    static func preference(in defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: preferenceKey) as? Bool) ?? true
    }
}
