import AppKit
import SwiftUI

extension EnvironmentValues {
    /// Toolbar content has no geometry of its own to read, so `ContentView` measures the window for it.
    @Entry var mainWindowWidth: CGFloat = 0
}

/// The toolbar hands out space without proposing any, so the field's width rules are arithmetic over the window.
enum ToolbarSearchMetrics {
    static let restingWidth: CGFloat = 180
    static let focusedWidth: CGFloat = 260
    static let chipSide: CGFloat = 28
    /// Below this a field is a sliver: the chip expands to at least this much or stays a chip.
    static let minimumFieldWidth: CGFloat = 132

    /// Measured on the built toolbar at 1180: 248 pt of lights and sidebar toggle, the 9 pt and 7 pt gaps
    /// around the field, and 50.5 pt of New menu and window inset.
    static let chromeBesideSearch: CGFloat = 314.5
    /// What the capsule is worth before it has reported its own width: the widest stock pair, measured the same way.
    static let defaultIntakeWidth: CGFloat = 393

    static func isShown(introductionPresented: Bool) -> Bool {
        !introductionPresented
    }

    static func roomForSearch(windowWidth: CGFloat, intakeWidth: CGFloat) -> CGFloat {
        windowWidth - chromeBesideSearch - intakeWidth
    }

    /// An unmeasured window proposes nothing, so it keeps the full field rather than flashing the chip.
    static func isTight(windowWidth: CGFloat, intakeWidth: CGFloat) -> Bool {
        windowWidth > 0 && roomForSearch(windowWidth: windowWidth, intakeWidth: intakeWidth) < focusedWidth
    }

    /// A drag-resize must not take the field out from under the caret, so a focused field never collapses.
    static func collapses(windowWidth: CGFloat, intakeWidth: CGFloat, isFocused: Bool) -> Bool {
        !isFocused && isTight(windowWidth: windowWidth, intakeWidth: intakeWidth)
    }

    /// A chip opened on a narrow toolbar takes the room that is left rather than pushing the New menu off the edge.
    static func fieldWidth(windowWidth: CGFloat, intakeWidth: CGFloat, focused: Bool) -> CGFloat {
        let wanted = focused ? focusedWidth : restingWidth
        guard isTight(windowWidth: windowWidth, intakeWidth: intakeWidth) else { return wanted }
        return max(minimumFieldWidth, min(wanted, roomForSearch(windowWidth: windowWidth, intakeWidth: intakeWidth)))
    }

    enum EscapeOutcome: Equatable {
        case clear
        case resignFocus
    }

    @MainActor
    static func escape(isEmpty: Bool) -> EscapeOutcome {
        SearchPill.escapeOutcome(clearsOnEscape: true, isEmpty: isEmpty) == .clear ? .clear : .resignFocus
    }
}

/// `FocusState` never takes on a field hosted in the window toolbar, so the caret and the field's keyboard state go through AppKit.
@MainActor
enum ToolbarSearchFocus {
    @discardableResult
    static func placeCaret() -> Bool {
        guard let (window, field) = locate() else { return false }
        if window.firstResponder !== field { previousResponder = window.firstResponder as? NSView }
        return window.makeFirstResponder(field)
    }

    /// Handing the keyboard to the window itself would take the content's own key handling and Tab order with it.
    static func resignCaret() {
        guard let (window, field) = locate() else { return }
        let restored = previousResponder.flatMap { $0.window === window && $0 !== field ? $0 : nil }
        previousResponder = nil
        window.makeFirstResponder(restored ?? window.contentView)
    }

    private static weak var previousResponder: NSView?

    /// The field posts its begin-editing notification only once text changes, so the caret is read off the field editor instead.
    static func holdsCaret() -> Bool {
        locate()?.field.currentEditor() != nil
    }

    private static func locate() -> (window: NSWindow, field: NSTextField)? {
        if let cached, cached.field.window != nil { return cached }
        for window in NSApp.windows where window.isVisible {
            if let field = toolbarField(in: window) {
                cached = (window, field)
                return cached
            }
        }
        cached = nil
        return nil
    }

    private static var cached: (window: NSWindow, field: NSTextField)?

    private static func toolbarField(in window: NSWindow) -> NSTextField? {
        guard let titlebar = window.contentView?.superview?.subviews.first(where: isTitlebar) else { return nil }
        return firstEditableField(in: titlebar)
    }

    private static func isTitlebar(_ view: NSView) -> Bool {
        String(describing: type(of: view)).contains("Titlebar")
    }

    private static func firstEditableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let found = firstEditableField(in: subview) { return found }
        }
        return nil
    }
}

struct ToolbarSearchField: View {
    /// The capsule's measured width, or 0 on a page that does not show it.
    let intakeWidth: CGFloat

    @Environment(AppModel.self) private var model
    @Environment(\.mainWindowWidth) private var windowWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editing = false
    @State private var expanded = false

    var body: some View {
        Group {
            if collapsed {
                expandChip
            } else {
                field
            }
        }
        .animation(reduceMotion ? nil : DS.Motion.resize, value: editing)
        .animation(reduceMotion ? nil : DS.Motion.resize, value: collapsed)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didUpdateNotification)) { _ in
            guard !collapsed else { return }
            let holdsCaret = ToolbarSearchFocus.holdsCaret()
            guard holdsCaret != editing else { return }
            editing = holdsCaret
            if !holdsCaret, model.searchQuery.isEmpty { expanded = false }
        }
        .onChange(of: model.librarySearchFocusRequests) { _, _ in
            expanded = true
            // The field is not on screen yet on the frame the chip gives way to it, so the caret ask waits a runloop turn.
            DispatchQueue.main.async { ToolbarSearchFocus.placeCaret() }
        }
    }

    private var collapsed: Bool {
        !expanded && ToolbarSearchMetrics.collapses(
            windowWidth: windowWidth,
            intakeWidth: intakeWidth,
            isFocused: editing
        )
    }

    private var query: Binding<String> {
        Binding(get: { model.searchQuery }, set: { model.search($0) })
    }

    private var field: some View {
        HStack(spacing: DS.Spacing.snug) {
            Image(systemName: "magnifyingglass")
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
            TextField("Search history", text: query)
                .textFieldStyle(.plain)
                .font(DS.Font.secondary)
                .axLeaf("Toolbar.TextField.Search")
                .onKeyPress(.escape) { escape() }
            if !model.searchQuery.isEmpty {
                clearButton
            }
        }
        .padding(.horizontal, DS.Spacing.small)
        .frame(
            width: ToolbarSearchMetrics.fieldWidth(
                windowWidth: windowWidth,
                intakeWidth: intakeWidth,
                focused: editing
            )
        )
        .toolbarCapsule(focused: editing)
    }

    private var clearButton: some View {
        Button {
            model.search("")
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Clear search")
        .accessibilityLabel("Clear search")
        .axLeaf("Toolbar.TextField.Search.Clear")
    }

    private var expandChip: some View {
        Button {
            expanded = true
            DispatchQueue.main.async { ToolbarSearchFocus.placeCaret() }
        } label: {
            Image(systemName: "magnifyingglass")
                .overlay(alignment: .topTrailing) {
                    if !model.searchQuery.isEmpty {
                        Circle()
                            .fill(DS.Color.accent)
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: -2)
                    }
                }
        }
        .buttonStyle(DSIconChipButtonStyle(side: ToolbarSearchMetrics.chipSide))
        .help(chipLabel)
        .accessibilityLabel(chipLabel)
        .axLeaf("Toolbar.Button.ExpandSearch")
    }

    /// The chip hides the query, so what it is filtering by has to reach the tooltip and VoiceOver.
    private var chipLabel: String {
        let query = model.searchQuery.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? String(localized: "Search history") : String(localized: "Searching for “\(query)”")
    }

    private func escape() -> KeyPress.Result {
        switch ToolbarSearchMetrics.escape(isEmpty: model.searchQuery.isEmpty) {
        case .clear:
            model.search("")
        case .resignFocus:
            ToolbarSearchFocus.resignCaret()
        }
        return .handled
    }
}
