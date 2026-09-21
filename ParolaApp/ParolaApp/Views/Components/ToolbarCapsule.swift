import SwiftUI

enum ToolbarCapsule {
    static let height: CGFloat = 28
    static let fillOpacity: Double = 0.85
    static let strokeOpacity: Double = 0.4

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
    }
}

/// The shell the toolbar's capsules share, so the search field and the intake capsule read as one family.
struct ToolbarCapsuleChrome: ViewModifier {
    var focused = false

    func body(content: Content) -> some View {
        content
            .frame(height: ToolbarCapsule.height)
            .background(ToolbarCapsule.shape.fill(DS.Color.surfaceElevated.opacity(ToolbarCapsule.fillOpacity)))
            .clipShape(ToolbarCapsule.shape)
            .overlay(
                ToolbarCapsule.shape
                    .strokeBorder(
                        focused ? DS.Color.accent : DS.Color.separator.opacity(ToolbarCapsule.strokeOpacity),
                        lineWidth: focused ? 1 : 0.5
                    )
            )
    }
}

extension View {
    func toolbarCapsule(focused: Bool = false) -> some View {
        modifier(ToolbarCapsuleChrome(focused: focused))
    }
}
