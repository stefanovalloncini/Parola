import AppIntents
import Foundation

public extension Notification.Name {
    static let parolaStartDictation = Notification.Name("com.parola.startDictation")
    static let parolaStopDictation = Notification.Name("com.parola.stopDictation")
}

/// Cross-process channel for dictation triggers. `NotificationCenter.default` is
/// process-local, so intents hosted out-of-process (Siri / Shortcuts) need a Darwin
/// notification to reach the running app. The app subscribes via `subscribe`; the
/// intent posts via `start` / `stop`.
public enum DictationSignal: Sendable {
    public static let startName: String = "com.parola.dictation.start"
    public static let stopName: String = "com.parola.dictation.stop"

    public static func start() {
        post(startName)
    }

    public static func stop() {
        post(stopName)
    }

    private static func post(_ name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    public static func subscribe(handler: @escaping @Sendable (String) -> Void) -> DictationSubscription {
        let token = DictationSubscription(handler: handler)
        token.register()
        return token
    }
}

public final class DictationSubscription: @unchecked Sendable {
    let handler: @Sendable (String) -> Void

    init(handler: @escaping @Sendable (String) -> Void) {
        self.handler = handler
    }

    func register() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let callback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer, let name else { return }
            let token = Unmanaged<DictationSubscription>.fromOpaque(observer).takeUnretainedValue()
            token.handler(name.rawValue as String)
        }
        CFNotificationCenterAddObserver(
            center,
            observer,
            callback,
            DictationSignal.startName as CFString,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            observer,
            callback,
            DictationSignal.stopName as CFString,
            nil,
            .deliverImmediately
        )
    }

    public func cancel() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveEveryObserver(center, observer)
    }

    deinit {
        cancel()
    }
}

public struct StartDictationIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Dictation"
    public static let description = IntentDescription("Starts a push-to-talk dictation session in Parola.")
    public static let openAppWhenRun: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        DictationSignal.start()
        await MainActor.run {
            NotificationCenter.default.post(name: .parolaStartDictation, object: nil)
        }
        return .result()
    }
}

public struct StopDictationIntent: AppIntent {
    public static let title: LocalizedStringResource = "Stop Dictation"
    public static let description = IntentDescription("Stops the current dictation session in Parola and inserts the result.")
    public static let openAppWhenRun: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        DictationSignal.stop()
        await MainActor.run {
            NotificationCenter.default.post(name: .parolaStopDictation, object: nil)
        }
        return .result()
    }
}
