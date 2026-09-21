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

    /// Measured at 1180: 248 pt of lights and sidebar toggle, the 9 and 7 pt gaps, 50.5 pt of New menu and inset.
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

    /// A drag-resize must not take the field out from under the caret, and a page with its own search field keeps the toolbar's as a chip.
    static func collapses(
        windowWidth: CGFloat,
        intakeWidth: CGFloat,
        isFocused: Bool,
        pageHasOwnSearch: Bool
    ) -> Bool {
        guard !isFocused else { return false }
        return pageHasOwnSearch || isTight(windowWidth: windowWidth, intakeWidth: intakeWidth)
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
    /// Walking the titlebar is not free, so it happens only when the field is about to be needed.
    static func allowLookup() {
        lookupAllowed = true
    }

    @discardableResult
    static func placeCaret() -> Bool {
        allowLookup()
        guard let (window, field) = locate() else { return false }
        // A focused field answers with its field editor, not itself, so only a field that is not editing has an outgoing responder to keep.
        if field.currentEditor() == nil { previousResponder = window.firstResponder as? NSView }
        return window.makeFirstResponder(field)
    }

    /// Handing the keyboard to the window itself would take the content's own key handling and Tab order with it.
    static func resignCaret() {
        guard let (window, field) = locate() else { return }
        let restored = previousResponder.flatMap { $0.window === window && $0 !== field ? $0 : nil }
        previousResponder = nil
        window.makeFirstResponder(restored ?? window.contentView)
    }

    /// The field posts its begin-editing notification only once text changes, so the caret is read off the field editor instead.
    static func holdsCaret() -> Bool {
        locate()?.field.currentEditor() != nil
    }

    private static weak var cachedWindow: NSWindow?
    private static weak var cachedField: NSTextField?
    private static weak var previousResponder: NSView?
    private static var lookupAllowed = true

    private static func locate() -> (window: NSWindow, field: NSTextField)? {
        if let cachedWindow, let cachedField, cachedField.window === cachedWindow { return (cachedWindow, cachedField) }
        guard lookupAllowed else { return nil }
        lookupAllowed = false
        for window in searchOrder() {
            guard let field = toolbarField(in: window) else { continue }
            cachedWindow = window
            cachedField = field
            return (window, field)
        }
        return nil
    }

    /// The field belongs to the window being used, so start there instead of at the head of `NSApp.windows`.
    private static func searchOrder() -> [NSWindow] {
        let preferred = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        return preferred + NSApp.windows.filter { $0.isVisible && !preferred.contains($0) }
    }

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
    /// Queue, Batch and Recently Deleted filter themselves; the toolbar's field stays a chip there.
    let pageHasOwnSearch: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.mainWindowWidth) private var windowWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editing = false
    @State private var expanded = false
    @State private var hasMeasuredWidth = false

    var body: some View {
        Group {
            if collapsed {
                expandChip
            } else {
                field
            }
        }
        .animation(reduceMotion ? nil : DS.Motion.resize, value: editing)
        // An unmeasured window renders the field first, so its first swap to the chip must not animate.
        .animation(reduceMotion || !hasMeasuredWidth ? nil : DS.Motion.resize, value: collapsed)
        .onChange(of: windowWidth) { _, measured in if measured > 0 { hasMeasuredWidth = true } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didUpdateNotification)) { note in
            guard !collapsed, (note.object as? NSWindow)?.isKeyWindow == true else { return }
            let holdsCaret = ToolbarSearchFocus.holdsCaret()
            guard holdsCaret != editing else { return }
            editing = holdsCaret
            if !holdsCaret, model.searchQuery.isEmpty { expanded = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            ToolbarSearchFocus.allowLookup()
        }
        .onChange(of: model.librarySearchFocusRequests) { _, _ in
            requestCaret()
        }
    }

    private var collapsed: Bool {
        !expanded && ToolbarSearchMetrics.collapses(
            windowWidth: windowWidth,
            intakeWidth: intakeWidth,
            isFocused: editing,
            pageHasOwnSearch: pageHasOwnSearch
        )
    }

    private var query: Binding<String> {
        Binding(get: { model.searchQuery }, set: { model.search($0) })
    }

    private var field: some View {
        HStack(spacing: DS.Spacing.snug) {
            Image(systemName: "magnifyingglass")
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondaryText)
            TextField("Search library", text: query)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .accessibilityIdentifier("toolbar.search")
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
        // A click lands after a hover, so warming the lookup here keeps it off the event loop's back.
        .onHover { inside in if inside { ToolbarSearchFocus.allowLookup() } }
        .onAppear { ToolbarSearchFocus.allowLookup() }
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
            requestCaret()
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
        return query.isEmpty ? String(localized: "Search library") : String(localized: "Searching for “\(query)”")
    }

    /// The field is not on screen yet on the frame the chip gives way to it, so the ask waits a runloop turn — and one more before giving up.
    private func requestCaret() {
        expanded = true
        DispatchQueue.main.async {
            guard !ToolbarSearchFocus.placeCaret() else { return }
            DispatchQueue.main.async {
                guard !ToolbarSearchFocus.placeCaret(), model.searchQuery.isEmpty else { return }
                expanded = false
            }
        }
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
