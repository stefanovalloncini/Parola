import SwiftUI

enum SceneEntrance {
    /// How long the block at `order` waits before it comes in, so a scene reads top to bottom.
    static func delay(order: Int) -> Double {
        0.07 * Double(order)
    }
}

extension View {
    func sceneEntrance(order: Int) -> some View {
        modifier(SceneEntranceModifier(order: order))
    }
}

private struct SceneEntranceModifier: ViewModifier {
    let order: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .onAppear { withAnimation(animation) { shown = true } }
    }

    private var animation: Animation {
        guard !reduceMotion else { return DS.Motion.route }
        return .spring(response: 0.5, dampingFraction: 0.85).delay(SceneEntrance.delay(order: order))
    }
}
