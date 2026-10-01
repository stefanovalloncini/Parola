import SwiftUI

/// A take folds the main window's sidebar away and gives it back as it was, unless the user reopened it meanwhile.
enum SidebarCollapsePolicy {
    static func enter(current: NavigationSplitViewVisibility) -> NavigationSplitViewVisibility {
        .detailOnly
    }

    static func exit(
        previous: NavigationSplitViewVisibility,
        current: NavigationSplitViewVisibility,
        userChangedDuringTake: Bool
    ) -> NavigationSplitViewVisibility {
        userChangedDuringTake ? current : previous
    }

    /// From the count-in until the take lands or fails, including while it transcribes on its Stage.
    static func holds(_ take: RecordingSession?) -> Bool {
        guard let take else { return false }
        return !take.isOver
    }
}

/// The main window's sidebar, kept by the model so a window reopened mid-take finds it as the take left it.
@MainActor
@Observable
final class MainSidebar {
    private(set) var visibility: NavigationSplitViewVisibility = .automatic
    @ObservationIgnored private var visibilityBeforeTake: NavigationSplitViewVisibility?
    @ObservationIgnored private var movedDuringTake = false

    /// The split view's own changes, from its toolbar toggle or a drag; one made while a take holds the sidebar is the user's to keep.
    func userSet(_ newValue: NavigationSplitViewVisibility) {
        guard newValue != visibility else { return }
        if visibilityBeforeTake != nil { movedDuringTake = true }
        visibility = newValue
    }

    func hold(_ holds: Bool, animation: Animation?) {
        if holds {
            guard visibilityBeforeTake == nil else { return }
            visibilityBeforeTake = visibility
            movedDuringTake = false
            show(SidebarCollapsePolicy.enter(current: visibility), animation: animation)
        } else if let previous = visibilityBeforeTake {
            visibilityBeforeTake = nil
            show(
                SidebarCollapsePolicy.exit(previous: previous, current: visibility, userChangedDuringTake: movedDuringTake),
                animation: animation
            )
        }
    }

    private func show(_ newValue: NavigationSplitViewVisibility, animation: Animation?) {
        guard newValue != visibility else { return }
        withAnimation(animation) { visibility = newValue }
    }
}

/// Hands each change in whether a take holds the sidebar to the model's sidebar, with the collapse spring.
struct TakeSidebarHold: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.onChange(of: SidebarCollapsePolicy.holds(model.recording), initial: true) { _, holds in
            model.mainSidebar.hold(holds, animation: reduceMotion ? nil : DS.Motion.sidebarCollapse)
        }
    }
}
