import SwiftUI

enum IntroductionLayout {
    /// The usable width every scene lays its content out in. The page margins sit outside it, so a
    /// scene can run a headline or an image edge to edge across exactly this much.
    static let columnWidth: CGFloat = 720
}

/// The whole window during the first run: one scene at a time over the canvas, with the step dots
/// and the navigation pills pinned to the bottom.
struct IntroductionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var demo = DemoPlayback()

    var body: some View {
        let introduction = model.introduction
        return ZStack {
            DS.Palette.canvas.ignoresSafeArea()
            IntroductionGlow().ignoresSafeArea()
            VStack(spacing: DS.Spacing.large) {
                scene(introduction.step)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(introduction.step)
                    .transition(sceneTransition(back: introduction.isMovingBack))
                IntroductionBottomBar()
            }
            .frame(maxWidth: IntroductionLayout.columnWidth)
            .padding(DS.Spacing.xlarge)
        }
        .animation(sceneAnimation, value: introduction.step)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .axBranch("Introduction")
    }

    @ViewBuilder
    private func scene(_ step: IntroductionStep) -> some View {
        switch step {
        case .hello: HelloScene()
        case .transcribe: TranscribeScene(demo: demo)
        case .features: FeaturesScene()
        case .engine: EngineScene()
        case .ready: ReadyScene()
        }
    }

    private var sceneAnimation: Animation {
        reduceMotion ? DS.Motion.route : .spring(response: 0.5, dampingFraction: 0.85)
    }

    private func sceneTransition(back: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: back ? .leading : .trailing).combined(with: .opacity),
            removal: .move(edge: back ? .trailing : .leading).combined(with: .opacity)
        )
    }
}

/// A wash of accent light in the top-leading corner, drifting slowly so the canvas isn't dead flat.
private struct IntroductionGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height) * 0.55
            if reduceMotion {
                glow(radius: radius, drift: .zero)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let seconds = context.date.timeIntervalSinceReferenceDate
                    glow(
                        radius: radius,
                        drift: CGSize(width: sin(seconds * 0.21) * 14, height: cos(seconds * 0.17) * 10)
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func glow(radius: CGFloat, drift: CGSize) -> some View {
        RadialGradient(
            colors: [DS.Color.accentWash, DS.Color.accentWash.opacity(0)],
            center: .topLeading,
            startRadius: 0,
            endRadius: radius
        )
        .offset(x: drift.width, y: drift.height)
    }
}
