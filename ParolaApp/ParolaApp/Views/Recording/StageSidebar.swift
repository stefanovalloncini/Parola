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
    @ObservationIgnored private let defaults: UserDefaults

    /// Set while a take keeps a shown sidebar folded. The window saves the fold with its frame, so a launch that finds this unfolds it.
    nonisolated static let foldedByTakeKey = "sidebarFoldedByTake"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The split view's own changes, from its toolbar toggle or a drag; one made while a take holds the sidebar is the user's to keep.
    func userSet(_ newValue: NavigationSplitViewVisibility) {
        guard newValue != visibility else { return }
        if visibilityBeforeTake != nil {
            movedDuringTake = true
            defaults.removeObject(forKey: Self.foldedByTakeKey)
        }
        visibility = newValue
    }

    func hold(_ holds: Bool, animation: Animation?) {
        if holds {
            guard visibilityBeforeTake == nil else { return }
            visibilityBeforeTake = visibility
            movedDuringTake = false
            let folded = SidebarCollapsePolicy.enter(current: visibility)
            if folded != visibility { defaults.set(true, forKey: Self.foldedByTakeKey) }
            show(folded, animation: animation)
        } else if let previous = visibilityBeforeTake {
            visibilityBeforeTake = nil
            defaults.removeObject(forKey: Self.foldedByTakeKey)
            show(
                SidebarCollapsePolicy.exit(previous: previous, current: visibility, userChangedDuringTake: movedDuringTake),
                animation: animation
            )
        } else if defaults.bool(forKey: Self.foldedByTakeKey) {
            defaults.removeObject(forKey: Self.foldedByTakeKey)
            show(.all, animation: nil)
        }
    }

    private func show(_ newValue: NavigationSplitViewVisibility, animation: Animation?) {
        guard newValue != visibility else { return }
        withAnimation(animation) { visibility = newValue }
    }
}

/// Gives the sidebar back once no take holds it, and at launch undoes a fold a crash left; the Stage folds it on its own appearance.
struct TakeSidebarRelease: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.onChange(of: SidebarCollapsePolicy.holds(model.recording), initial: true) { _, holds in
            guard !holds else { return }
            model.mainSidebar.hold(false, animation: reduceMotion ? nil : DS.Motion.sidebarCollapse)
        }
    }
}

/// Folds the sidebar one hop after the Stage appears: the page the Stage replaced is gone by then, so the split view never collapses over a List being dismantled.
struct StageSidebarFold: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.onAppear {
            let animation = reduceMotion ? nil : DS.Motion.sidebarCollapse
            Task { @MainActor in
                guard SidebarCollapsePolicy.holds(model.recording) else { return }
                model.mainSidebar.hold(true, animation: animation)
            }
        }
    }
}
