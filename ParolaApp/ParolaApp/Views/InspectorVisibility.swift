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

    static let modeKey = "inspectorMode"

    /// For actions whose result only lands in the inspector, so running one from elsewhere shows it.
    static func show(in defaults: UserDefaults, isNarrow: Bool) {
        defaults.set(true, forKey: isNarrow ? forcedAtNarrowWidthKey : preferenceKey)
    }

    /// Info is the only pane that renders chapters and action items, so showing the inspector is not enough.
    static func showInfo(in defaults: UserDefaults, isNarrow: Bool) {
        show(in: defaults, isNarrow: isNarrow)
        defaults.set(InspectorMode.info.rawValue, forKey: modeKey)
    }

    /// An unset key means visible, matching the pane's `@AppStorage` default.
    static func preference(in defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: preferenceKey) as? Bool) ?? true
    }
}
