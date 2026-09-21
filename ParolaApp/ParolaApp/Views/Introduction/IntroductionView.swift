import SwiftUI

enum IntroductionLayout {
    /// The usable width every scene lays its content out in; page margins sit outside it, so a scene can run edge to edge across exactly this much.
    static let columnWidth: CGFloat = 720

    /// The row every scene after Hello starts on, measured from the top of the stage: one shared
    /// anchor, so a headline never jumps when the scene changes.
    static func topInset(stageHeight: CGFloat) -> CGFloat {
        max(DS.Spacing.xlarge, floor(stageHeight * 0.20))
    }

    /// Hello is a centred lockup, but dead centre reads low with the bottom bar under it.
    static func helloCentre(stageHeight: CGFloat) -> CGFloat {
        stageHeight * 0.46
    }

    static func helloOffset(stageHeight: CGFloat) -> CGFloat {
        helloCentre(stageHeight: stageHeight) - stageHeight / 2
    }
}

/// The whole window during the first run: one scene at a time over the stage, with the step dots and navigation pills pinned to the bottom.
struct IntroductionView: View {
    enum TransitionKind {
        case fade
        case slide
    }

    /// Hello and the demo card trade the bars, so the scenes around them cross-fade instead of sliding past each other.
    nonisolated static func transitionKind(from: IntroductionStep, to: IntroductionStep) -> TransitionKind {
        let pair: Set<IntroductionStep> = [from, to]
        return pair == [.hello, .transcribe] ? .fade : .slide
    }

    /// A scene is removed with the transition it was built with, never one chosen for the move that takes it
    /// away, so the two that hand the bars over leave by fading whatever they are moving to.
    nonisolated static func leavesByFading(_ step: IntroductionStep) -> Bool {
        step == .hello || step == .transcribe
    }

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var brand
    // Held as an optional and filled on appear: a default value would open an AVAudioPlayer on every init.
    @State private var playback: DemoPlayback?

    var body: some View {
        let introduction = model.introduction
        let kind = Self.transitionKind(from: introduction.previousStep ?? introduction.step, to: introduction.step)
        return ZStack {
            IntroductionStage()
            VStack(spacing: DS.Spacing.large) {
                GeometryReader { proxy in
                    staged(introduction.step, stageHeight: proxy.size.height)
                        .id(introduction.step)
                        .transition(sceneTransition(
                            kind: kind,
                            step: introduction.step,
                            back: introduction.isMovingBack
                        ))
                }
                IntroductionBottomBar()
            }
            .frame(maxWidth: IntroductionLayout.columnWidth)
            .padding(DS.Spacing.xlarge)
        }
        .animation(sceneAnimation(kind: kind), value: introduction.step)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { if playback == nil { playback = DemoPlayback() } }
        .axBranch("Introduction")
    }

    @ViewBuilder
    private func staged(_ step: IntroductionStep, stageHeight: CGFloat) -> some View {
        if step == .hello {
            scene(step)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: IntroductionLayout.helloOffset(stageHeight: stageHeight))
        } else {
            scene(step)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, IntroductionLayout.topInset(stageHeight: stageHeight))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private func scene(_ step: IntroductionStep) -> some View {
        switch step {
        case .hello: HelloScene(brand: brand)
        case .transcribe:
            if let playback { TranscribeScene(demo: playback, brand: brand) }
        case .features: FeaturesScene()
        case .engine: EngineScene()
        case .ready: ReadyScene()
        }
    }

    private func sceneAnimation(kind: TransitionKind) -> Animation {
        guard !reduceMotion else { return DS.Motion.route }
        switch kind {
        case .fade: return .spring(response: 0.55, dampingFraction: 0.85)
        case .slide: return .spring(response: 0.5, dampingFraction: 0.85)
        }
    }

    private func sceneTransition(kind: TransitionKind, step: IntroductionStep, back: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        // One edge covers both phases: a scene arrives from the side opposite the edge it names and leaves towards it (measured, not documented).
        let edge: Edge = back ? .trailing : .leading
        let arriving: AnyTransition = kind == .fade ? .opacity : .move(edge: edge).combined(with: .opacity)
        let leaving: AnyTransition = Self.leavesByFading(step) ? .opacity : .move(edge: edge).combined(with: .opacity)
        return .asymmetric(insertion: arriving, removal: leaving)
    }
}
