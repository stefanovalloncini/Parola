import AppKit
import Foundation

/// Puts the dictation HUD where its style places it, or where the user dragged it, per style, as the recording pill remembers its spot.
@MainActor
final class DictationHUDPositioner {
    nonisolated static let spotsKey = "dictationHUDSpots"

    private let defaults: UserDefaults
    private let screens: @MainActor () -> [NSRect]
    private var style: DictationIndicatorStyle = .nearField
    private var placing = false
    private weak var observed: NSWindow?
    private var moveObserver: (any NSObjectProtocol)?

    init(defaults: UserDefaults, screens: @escaping @MainActor () -> [NSRect] = { NSScreen.screens.map(\.frame) }) {
        self.defaults = defaults
        self.screens = screens
    }

    isolated deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    func place(_ panel: NSWindow, _ context: DictationHUDPlacement.Context, animate: Bool = false) {
        watch(panel)
        style = context.style
        // Near-field follows the field it types into, so a drag would only snap back.
        panel.isMovableByWindowBackground = context.style != .nearField
        let frame = DictationHUDPlacement.frame(context, spot: spot(for: context.style), screens: screens())
        guard panel.frame != frame else { return }
        placing = true
        panel.setFrame(frame, display: true, animate: animate)
        placing = false
    }

    private func watch(_ panel: NSWindow) {
        guard observed !== panel else { return }
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        observed = panel
        // No queue: the move is handled as it's posted, while `placing` still tells our own moves from a drag.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.moved() }
        }
    }

    private func moved() {
        guard !placing, let frame = observed?.frame, style != .nearField else { return }
        var spots = storedSpots
        let spot = DictationHUDPlacement.spot(of: frame, style: style)
        spots[style.rawValue] = [spot.x, spot.y]
        defaults.set(spots, forKey: Self.spotsKey)
    }

    private func spot(for style: DictationIndicatorStyle) -> NSPoint? {
        guard let pair = storedSpots[style.rawValue], pair.count == 2 else { return nil }
        return NSPoint(x: pair[0], y: pair[1])
    }

    private var storedSpots: [String: [Double]] {
        defaults.dictionary(forKey: Self.spotsKey) as? [String: [Double]] ?? [:]
    }
}
