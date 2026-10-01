import AppKit
import ObjectiveC

/// Closing the main window during a take asks what ⌘Q asks, and nothing quits.
@MainActor
enum MainWindowClose {
    /// A take that Stop or Discard can still end; one that is finishing is already on its way to the library.
    nonisolated static func asks(take: RecordingSession?) -> Bool {
        TakeRemote.canEnd(take)
    }

    /// Keep Recording keeps the window; Stop and Save closes it once the take's audio is on disk; Discard… asks again first; only the take asked about is acted on.
    static func resolve(
        _ choice: AppModel.QuitDuringTake,
        about takeID: Int,
        model: AppModel,
        confirmDiscard: @MainActor () async -> Bool,
        close: @MainActor () -> Void
    ) async {
        let asked = model.recording?.takeID == takeID ? model.recording : nil
        switch choice {
        case .keepRecording:
            return
        case .stopAndSave:
            if TakeRemote.canEnd(asked) { TakeRemote.stop(model) }
        case .discard:
            if let asked, asked.isArming || TakeRemote.canDiscard(asked) {
                guard await TakeRemote.discard(model, confirm: confirmDiscard) else { return }
            }
        }
        await model.takeHasWoundDown(takeID)
        close()
    }
}

/// SwiftUI's own window delegate with one question in front of it: everything else is passed through untouched.
@MainActor
final class MainWindowCloseGuard: NSObject, NSWindowDelegate {
    private static let associationKey = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    private weak var model: AppModel?
    // Read by the Objective-C forwarding below, which AppKit only sends on the main thread.
    nonisolated(unsafe) private weak var forwarded: NSObject?
    private let ask: @MainActor (NSWindow) async -> AppModel.QuitDuringTake
    private let confirmDiscard: @MainActor (NSWindow) async -> Bool
    private var closingAsAnswered = false

    var wrapped: NSObject? { forwarded }

    private init(
        model: AppModel,
        forwarded: NSObject?,
        ask: @escaping @MainActor (NSWindow) async -> AppModel.QuitDuringTake,
        confirmDiscard: @escaping @MainActor (NSWindow) async -> Bool
    ) {
        self.model = model
        self.forwarded = forwarded
        self.ask = ask
        self.confirmDiscard = confirmDiscard
    }

    /// Wraps the window's delegate once; the window keeps the wrapper, since its delegate is only a weak reference.
    @discardableResult
    static func install(
        on window: NSWindow,
        model: AppModel,
        ask: @escaping @MainActor (NSWindow) async -> AppModel.QuitDuringTake = AppDelegate.askAboutClosing,
        confirmDiscard: @escaping @MainActor (NSWindow) async -> Bool = TakeRemote.askToDiscard(on:)
    ) -> MainWindowCloseGuard {
        if let installed = window.delegate as? MainWindowCloseGuard {
            installed.model = model
            return installed
        }
        let closeGuard = MainWindowCloseGuard(
            model: model, forwarded: window.delegate as? NSObject, ask: ask, confirmDiscard: confirmDiscard
        )
        objc_setAssociatedObject(window, associationKey, closeGuard, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        window.delegate = closeGuard
        return closeGuard
    }

    /// The window stays while the sheet asks; AppKit refuses another close as long as the sheet is up.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closingAsAnswered, let model, let take = model.recording, MainWindowClose.asks(take: take) else {
            return (forwarded as? any NSWindowDelegate)?.windowShouldClose?(sender) ?? true
        }
        let ask = ask
        let confirmDiscard = confirmDiscard
        Task { [weak self] in
            let choice = await ask(sender)
            await MainWindowClose.resolve(choice, about: take.takeID, model: model, confirmDiscard: { await confirmDiscard(sender) }) {
                guard sender.isVisible || sender.isMiniaturized else { return }
                self?.closeAsAnswered(sender)
            }
        }
        return false
    }

    /// The answer already covers this close, so a take started while the sheet was up doesn't ask again.
    private func closeAsAnswered(_ window: NSWindow) {
        closingAsAnswered = true
        window.performClose(nil)
        closingAsAnswered = false
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || forwarded?.responds(to: aSelector) == true
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let forwarded, forwarded.responds(to: aSelector) { return forwarded }
        return super.forwardingTarget(for: aSelector)
    }
}

extension AppModel {
    /// Returns once that take's capture has wound down and its audio is on disk, or a newer take has taken its place; its transcription may still be running.
    func takeHasWoundDown(_ takeID: Int) async {
        while recording?.takeID == takeID, takeIsRunning {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = recording
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }
}
