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

    /// The edge a move names: a scene arrives from the trailing side going forward and from the leading side on Back.
    nonisolated static func moveEdge(back: Bool) -> Edge {
        back ? .trailing : .leading
    }

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(DemoPlayback.self) private var playback: DemoPlayback?
    @Namespace private var brand

    var body: some View {
        let introduction = model.introduction
        let kind = Self.transitionKind(from: introduction.previousStep ?? introduction.step, to: introduction.step)
        return ZStack {
            IntroductionStage()
            VStack(spacing: DS.Spacing.large) {
                GeometryReader { proxy in
                    staged(introduction.step, stageHeight: proxy.size.height)
                        .id(introduction.step)
                        .transition(sceneTransition(kind: kind, back: introduction.isMovingBack))
                }
                IntroductionBottomBar()
            }
            .frame(maxWidth: IntroductionLayout.columnWidth)
            .padding(DS.Spacing.xlarge)
        }
        .animation(sceneAnimation(kind: kind), value: introduction.step)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// The arriving scene carries the whole direction: a node is removed with the transition it was built with, which predates the move taking it away.
    private func sceneTransition(kind: TransitionKind, back: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let arriving: AnyTransition = kind == .fade ? .opacity : .move(edge: Self.moveEdge(back: back))
        return .asymmetric(insertion: arriving, removal: .opacity)
    }
}

extension View {
    /// Holds the demo clip above `ContentView`'s theme identity, so changing the accent mid-introduction doesn't rebuild the player and replay the audio.
    func demoPlayback() -> some View {
        modifier(DemoPlaybackOwner())
    }
}

private struct DemoPlaybackOwner: ViewModifier {
    @Environment(AppModel.self) private var model
    // Built when the introduction opens rather than up front: a player at launch would decode the clip for everyone.
    @State private var playback: DemoPlayback?

    func body(content: Content) -> some View {
        content
            .environment(playback)
            .task(id: model.introduction.isPresented) {
                guard model.introduction.isPresented else { return }
                playback = DemoPlayback()
            }
    }
}
