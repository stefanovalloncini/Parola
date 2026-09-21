import SwiftUI

enum IntroductionLayout {
    /// The usable width every scene lays its content out in; page margins sit outside it, so a scene can run edge to edge across exactly this much.
    static let columnWidth: CGFloat = 720
}

/// The whole window during the first run: one scene at a time over the stage, with the step dots and navigation pills pinned to the bottom.
struct IntroductionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Held as an optional and filled on appear: a default value would open an AVAudioPlayer on every init.
    @State private var playback: DemoPlayback?

    var body: some View {
        let introduction = model.introduction
        return ZStack {
            IntroductionStage()
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
        .task { if playback == nil { playback = DemoPlayback() } }
        .axBranch("Introduction")
    }

    @ViewBuilder
    private func scene(_ step: IntroductionStep) -> some View {
        switch step {
        case .hello: HelloScene()
        case .transcribe:
            if let playback { TranscribeScene(demo: playback) }
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
