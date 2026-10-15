import Foundation

/// How an app-only capture ended: the app quit, or it is still running but its audio went away.
public enum TapEnd: Sendable, Equatable {
    case quit
    case stoppedSending

    public init(processesLeft: Bool) {
        self = processesLeft ? .stoppedSending : .quit
    }

    /// Waits out `settle`, then asks again, so a helper that respawns reads as a respawn and not a quit; nil if cancelled meanwhile.
    public static func settled(
        after settle: Duration, on clock: any Clock<Duration>, processesLeft: @Sendable () -> Bool
    ) async -> TapEnd? {
        guard (try? await clock.sleep(for: settle)) != nil else { return nil }
        return TapEnd(processesLeft: processesLeft())
    }
}
