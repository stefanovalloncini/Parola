import Foundation

/// A source that can tell its watched processes are gone; system-audio sources don't, so their `whenCaptureEnds` stays as it was.
public protocol TargetsGoneReporting: LiveAudioSource {
    func whenTargetsGone(_ handler: @escaping @Sendable () -> Void) async
    /// The process objects watched now.
    func watchedProcessObjects() async -> [UInt32]
    /// Watches only `survivors` from here on, reporting the next departure to `handler`.
    func rewatchTargets(_ survivors: [UInt32], _ handler: @escaping @Sendable () -> Void) async
}

public extension TargetsGoneReporting {
    func watchedProcessObjects() async -> [UInt32] { [] }
    func rewatchTargets(_ survivors: [UInt32], _ handler: @escaping @Sendable () -> Void) async {
        await whenTargetsGone(handler)
    }
}

/// How an app-only capture ended: the app quit, or it is still running but its audio went away.
public enum TapEnd: Sendable, Equatable {
    case quit
    case stoppedSending

    /// What the process list says now: the bundle's objects, and whether one is playing.
    public struct Probe: Sendable {
        public var objects: @Sendable () -> [UInt32]
        public var isRunningOutput: @Sendable (UInt32) -> Bool

        public init(objects: @escaping @Sendable () -> [UInt32], isRunningOutput: @escaping @Sendable (UInt32) -> Bool) {
            self.objects = objects
            self.isRunningOutput = isRunningOutput
        }
    }

    enum Verdict: Sendable, Equatable {
        case ended(TapEnd)
        case alive(survivors: [UInt32])
    }

    /// A process that still plays keeps the tap fed, so only an end with no one outputting counts.
    static func verdict(watched: [UInt32], probe: Probe) -> Verdict {
        let current = probe.objects()
        guard !current.isEmpty else { return .ended(.quit) }
        let survivors = watched.filter(current.contains)
        if survivors.contains(where: probe.isRunningOutput) { return .alive(survivors: survivors) }
        if current.contains(where: { !watched.contains($0) }) { return .ended(.stoppedSending) }
        return .alive(survivors: survivors)
    }

    /// Waits out `settle`, then reads the verdict; nil if cancelled meanwhile.
    static func settled(after settle: Duration, on clock: any Clock<Duration>, watched: [UInt32], probe: Probe) async -> Verdict? {
        guard (try? await clock.sleep(for: settle)) != nil else { return nil }
        return verdict(watched: watched, probe: probe)
    }

    /// The end once settled; a tap that is still alive is watched again through `rearm`, and gives nil.
    public static func resolve(
        _ tap: any TargetsGoneReporting, after settle: Duration, on clock: any Clock<Duration>, probe: Probe,
        rearm: @escaping @Sendable () -> Void
    ) async -> TapEnd? {
        let watched = await tap.watchedProcessObjects()
        switch await settled(after: settle, on: clock, watched: watched, probe: probe) {
        case .ended(let end): return end
        case .alive(let survivors):
            await tap.rewatchTargets(survivors, rearm)
            return nil
        case nil: return nil
        }
    }
}
