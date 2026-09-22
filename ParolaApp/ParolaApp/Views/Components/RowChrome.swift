import SwiftUI

/// How a row says it is the chosen one. Hover looks the same everywhere, so only selection varies.
enum RowSelectionStyle: Equatable {
    /// A solid accent fill with a legible foreground on it: sidebars and menu-like popovers.
    case prominent(fill: Color, foreground: Color? = nil)
    /// A tinted wash, with an outline where the row needs one: content rows and cards.
    case wash(fill: Color, border: Color? = nil)
    /// A row inside a `List`: the system paints the selection, the row paints only its hover.
    case native
}

struct RowChromeState: Equatable {
    var selected: Bool
    var hovered: Bool

    /// A `List` paints its own selection at once, so a native row animates its hover and nothing else.
    func animationValue(for selection: RowSelectionStyle) -> RowChromeState {
        guard case .native = selection else { return self }
        return RowChromeState(selected: false, hovered: hovered)
    }
}

/// What a row draws in one state. Selection beats hover, so a selected row never washes.
struct RowChromeAppearance: Equatable {
    var fill: Color
    var border: Color?
    var foreground: Color?

    init(state: RowChromeState, selection: RowSelectionStyle) {
        guard state.selected else {
            fill = state.hovered ? DS.Palette.surfaceHover : .clear
            border = nil
            foreground = nil
            return
        }
        switch selection {
        case .prominent(let fill, let foreground):
            self.fill = fill
            self.border = nil
            self.foreground = foreground
        case .wash(let fill, let border):
            self.fill = fill
            self.border = border
            self.foreground = nil
        case .native:
            fill = .clear
            border = nil
            foreground = nil
        }
    }

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : DS.Motion.rowState
    }
}

private struct RowChrome: ViewModifier {
    let state: RowChromeState
    let radius: CGFloat
    let selection: RowSelectionStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let appearance = RowChromeAppearance(state: state, selection: selection)
        // One shape with an animatable fill: the three states have to interpolate, not swap views.
        return content
            .background(
                shape
                    .fill(appearance.fill)
                    .strokeBorder(appearance.border ?? .clear, lineWidth: 1)
            )
            .contentShape(shape)
            .modifier(SelectedForeground(color: appearance.foreground))
            .animation(
                RowChromeAppearance.animation(reduceMotion: reduceMotion),
                value: state.animationValue(for: selection)
            )
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

private struct SelectedForeground: ViewModifier {
    let color: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let color {
            content.foregroundStyle(color)
        } else {
            content
        }
    }
}

private struct RowStateAnimation<Value: Equatable>: ViewModifier {
    let value: Value

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(RowChromeAppearance.animation(reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// The background, hit area and state animation every hoverable row shares.
    func rowChrome(
        selected: Bool,
        hovered: Bool,
        radius: CGFloat = DS.Radius.small,
        selection: RowSelectionStyle
    ) -> some View {
        modifier(
            RowChrome(
                state: RowChromeState(selected: selected, hovered: hovered),
                radius: radius,
                selection: selection
            )
        )
    }

    /// `DS.Motion.rowState` with the reduce-motion gate, for chrome that isn't a row.
    func rowStateAnimation<Value: Equatable>(_ value: Value) -> some View {
        modifier(RowStateAnimation(value: value))
    }
}
