import AppIntents
import Foundation

public extension Notification.Name {
    static let parolaStartDictation = Notification.Name("com.parola.startDictation")
    static let parolaStopDictation = Notification.Name("com.parola.stopDictation")
}

/// Darwin notification channel that carries dictation triggers across processes (intents host -> app).
public enum DictationSignal: Sendable {
    public static let startName: String = "com.parola.dictation.start"
    public static let stopName: String = "com.parola.dictation.stop"

    /// The start and stop names one side posts and the other hears.
    public struct Names: Sendable, Equatable {
        public let start: String
        public let stop: String

        public init(start: String, stop: String) {
            self.start = start
            self.stop = stop
        }

        public static let parola = Names(start: DictationSignal.startName, stop: DictationSignal.stopName)
    }

    /// A Darwin notification reaches every process on the Mac, so a test binds names of its own here rather than post Parola's.
    @TaskLocal public static var names: Names = .parola

    public static func start() {
        post(names.start)
    }

    public static func stop() {
        post(names.stop)
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
        let token = DictationSubscription(names: names, handler: handler)
        token.register()
        return token
    }
}

/// Unchecked Sendable: `handler` is `@Sendable` and the only mutable state lives in CF's observer registry, which is thread-safe.
public final class DictationSubscription: @unchecked Sendable {
    let names: DictationSignal.Names
    let handler: @Sendable (String) -> Void

    init(names: DictationSignal.Names, handler: @escaping @Sendable (String) -> Void) {
        self.names = names
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
            names.start as CFString,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            observer,
            callback,
            names.stop as CFString,
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
        // Darwin only: the app's AppDelegate subscription covers in- and out-of-process
        // callers; a NotificationCenter post here double-fired the running app.
        DictationSignal.start()
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
        return .result()
    }
}
