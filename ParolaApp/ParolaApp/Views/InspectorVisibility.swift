import Foundation

/// Whether the transcript inspector shows: a comfortable pane follows the preference, a narrow one hides it until asked.
enum InspectorVisibility {
    static let preferenceKey = "inspectorVisible"
    static let forcedAtNarrowWidthKey = "inspectorForcedAtNarrowWidth"
    static let detailsExpandedKey = "inspectorDetailsExpanded"
    static let insightsExpandedKey = "inspectorInsightsExpanded"

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

    static func commandTitle(showing: Bool) -> String {
        showing ? String(localized: "Hide Inspector") : String(localized: "Show Inspector")
    }

    /// For actions whose result only lands in the inspector, so running one from elsewhere shows it.
    static func show(in defaults: UserDefaults, isNarrow: Bool) {
        defaults.set(true, forKey: isNarrow ? forcedAtNarrowWidthKey : preferenceKey)
    }

    /// An unset key means visible, matching the pane's `@AppStorage` default.
    static func preference(in defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: preferenceKey) as? Bool) ?? true
    }
}

/// The inspector sections a command can scroll to.
enum InspectorAnchor: Hashable {
    case chapters
    case actionItems
}

extension AppModel {
    /// Shows the inspector and scrolls it to `section`: Show Chapters, and the runs whose results land there.
    func revealInInspector(_ section: InspectorAnchor) {
        InspectorVisibility.show(in: DefaultsStore.current, isNarrow: transcriptPaneIsNarrow)
        inspectorReveal = section
    }
}
