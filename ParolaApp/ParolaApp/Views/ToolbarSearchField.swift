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

    /// Measured on the live toolbar at 1180: 251.5 pt of lights and sidebar toggle before the capsule,
    /// 8 pt of gap after it, and 62.5 pt of New menu and window inset after the field.
    static let chromeBesideSearch: CGFloat = 322
    /// The fused intake capsule at its widest stock labels ("Apple Speech (system)" + "Auto-detect"), measured the same way.
    static let intakeCapsuleWidth: CGFloat = 386

    static func isShown(introductionPresented: Bool) -> Bool {
        !introductionPresented
    }

    static func roomForSearch(windowWidth: CGFloat, intakeShown: Bool) -> CGFloat {
        windowWidth - chromeBesideSearch - (intakeShown ? intakeCapsuleWidth : 0)
    }

    /// An unmeasured window proposes nothing, so it keeps the full field rather than flashing the chip.
    static func collapses(windowWidth: CGFloat, intakeShown: Bool) -> Bool {
        windowWidth > 0 && roomForSearch(windowWidth: windowWidth, intakeShown: intakeShown) < focusedWidth
    }

    /// A chip opened on a narrow toolbar takes the room that is left rather than pushing the New menu off the edge.
    static func fieldWidth(windowWidth: CGFloat, intakeShown: Bool, focused: Bool) -> CGFloat {
        let wanted = focused ? focusedWidth : restingWidth
        guard collapses(windowWidth: windowWidth, intakeShown: intakeShown) else { return wanted }
        return max(minimumFieldWidth, min(wanted, roomForSearch(windowWidth: windowWidth, intakeShown: intakeShown)))
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

struct ToolbarSearchField: View {
    let intakeShown: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.mainWindowWidth) private var windowWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var expanded = false

    var body: some View {
        Group {
            if collapsed {
                expandChip
            } else {
                field
            }
        }
        .animation(reduceMotion ? nil : DS.Motion.resize, value: focused)
        .animation(reduceMotion ? nil : DS.Motion.resize, value: collapsed)
        .onChange(of: focused) { _, nowFocused in
            guard !nowFocused, model.searchQuery.isEmpty else { return }
            expanded = false
        }
        .onChange(of: model.librarySearchFocusRequests) { _, _ in
            expanded = true
            // The field is not first responder on the frame it appears in, so the ask waits a runloop turn.
            DispatchQueue.main.async { focused = true }
        }
    }

    private var collapsed: Bool {
        !expanded && ToolbarSearchMetrics.collapses(windowWidth: windowWidth, intakeShown: intakeShown)
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
                .focused($focused)
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
                intakeShown: intakeShown,
                focused: focused
            )
        )
        .toolbarCapsule(focused: focused)
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
            // The field is not first responder on the frame it appears in, so the ask waits a runloop turn.
            DispatchQueue.main.async { focused = true }
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .buttonStyle(DSIconChipButtonStyle(side: ToolbarSearchMetrics.chipSide))
        .help("Search history")
        .accessibilityLabel("Search history")
        .axLeaf("Toolbar.Button.ExpandSearch")
    }

    private func escape() -> KeyPress.Result {
        switch ToolbarSearchMetrics.escape(isEmpty: model.searchQuery.isEmpty) {
        case .clear:
            model.search("")
        case .resignFocus:
            focused = false
            expanded = false
        }
        return .handled
    }
}
