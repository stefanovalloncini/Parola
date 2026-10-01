import AppKit
import ObjectiveC

/// Closing the main window during a take asks what ⌘Q asks, and nothing quits.
@MainActor
enum MainWindowClose {
    /// A take that Stop or Discard can still end; one that is finishing is already on its way to the library.
    nonisolated static func asks(take: RecordingSession?) -> Bool {
        TakeRemote.canEnd(take)
    }

    /// Keep Recording keeps the window; Stop and Save closes it once the take's audio is on disk; Discard… asks again first.
    static func resolve(
        _ choice: AppModel.QuitDuringTake,
        model: AppModel,
        confirmDiscard: @MainActor () async -> Bool,
        close: @MainActor () -> Void
    ) async {
        switch choice {
        case .keepRecording:
            return
        case .stopAndSave:
            TakeRemote.stop(model)
        case .discard:
            guard await TakeRemote.discard(model, confirm: confirmDiscard) else { return }
        }
        await model.takeHasWoundDown()
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
    private let ask: @MainActor () -> AppModel.QuitDuringTake
    private let confirmDiscard: @MainActor () async -> Bool

    var wrapped: NSObject? { forwarded }

    private init(
        model: AppModel,
        forwarded: NSObject?,
        ask: @escaping @MainActor () -> AppModel.QuitDuringTake,
        confirmDiscard: @escaping @MainActor () async -> Bool
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
        ask: @escaping @MainActor () -> AppModel.QuitDuringTake = AppDelegate.presentCloseDuringTakeAlert,
        confirmDiscard: @escaping @MainActor () async -> Bool = TakeRemote.askToDiscard
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model, MainWindowClose.asks(take: model.recording) else {
            return (forwarded as? any NSWindowDelegate)?.windowShouldClose?(sender) ?? true
        }
        let choice = ask()
        guard choice != .keepRecording else { return false }
        let confirmDiscard = confirmDiscard
        Task { [weak sender] in
            await MainWindowClose.resolve(choice, model: model, confirmDiscard: confirmDiscard) {
                guard let sender, sender.isVisible || sender.isMiniaturized else { return }
                sender.performClose(nil)
            }
        }
        return false
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
    /// Returns once the take's capture has wound down and its audio is on disk; its transcription may still be running.
    func takeHasWoundDown() async {
        while takeIsRunning {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = takeIsRunning
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }
}
