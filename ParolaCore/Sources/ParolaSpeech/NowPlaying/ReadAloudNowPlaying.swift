import Foundation
import MediaPlayer

public enum NowPlayingCommand: Sendable, Hashable, CaseIterable {
    case play
    case pause
    case toggle
    case next
    case previous
}

@MainActor
public protocol NowPlayingPublishing: AnyObject {
    var onCommand: ((NowPlayingCommand) -> MPRemoteCommandHandlerStatus)? { get set }
    func publish(title: String, unitIndex: Int, unitCount: Int, isPlaying: Bool)
    func withdraw()
}

/// Publishes a reading to the system's Now Playing and routes its play, pause and skip keys back. Remote
/// command targets exist only between the first `publish` and `withdraw()`.
@MainActor
public final class ReadAloudNowPlaying: NowPlayingPublishing {
    public var onCommand: ((NowPlayingCommand) -> MPRemoteCommandHandlerStatus)?

    private var tokens: [(command: MPRemoteCommand, token: Any)] = []

    public init() {}

    public func publish(title: String, unitIndex: Int, unitCount: Int, isPlaying: Bool) {
        let center = MPNowPlayingInfoCenter.default()
        registerIfNeeded()
        center.nowPlayingInfo = Self.info(title: title, unitIndex: unitIndex, unitCount: unitCount)
        center.playbackState = isPlaying ? .playing : .paused
    }

    public func withdraw() {
        guard !tokens.isEmpty else { return }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        for (command, _) in tokens {
            command.removeTarget(nil)
            command.isEnabled = false
        }
        tokens.removeAll()
    }

    nonisolated static func info(title: String, unitIndex: Int, unitCount: Int) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Parola",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: unitIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: unitCount,
        ]
        if #available(macOS 15, *) { info[MPNowPlayingInfoPropertyExcludeFromSuggestions] = true }
        return info
    }

    // Built outside the @MainActor class: a closure formed there is inferred @MainActor and traps off main.
    nonisolated static func target(
        for command: NowPlayingCommand,
        route: @escaping @MainActor @Sendable (NowPlayingCommand) -> MPRemoteCommandHandlerStatus
    ) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { _ in
            if Thread.isMainThread {
                return MainActor.assumeIsolated { route(command) }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = route(command) } }
            return .success
        }
    }

    private func registerIfNeeded() {
        guard tokens.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        let route: @MainActor @Sendable (NowPlayingCommand) -> MPRemoteCommandHandlerStatus = { [weak self] command in
            self?.onCommand?(command) ?? .noActionableNowPlayingItem
        }
        let ours: [(NowPlayingCommand, MPRemoteCommand)] = [
            (.play, center.playCommand),
            (.pause, center.pauseCommand),
            (.toggle, center.togglePlayPauseCommand),
            (.next, center.nextTrackCommand),
            (.previous, center.previousTrackCommand),
        ]
        let others: [MPRemoteCommand] = [
            center.changePlaybackPositionCommand, center.skipForwardCommand, center.skipBackwardCommand,
            center.seekForwardCommand, center.seekBackwardCommand,
        ]
        for command in others { command.isEnabled = false }
        for (name, command) in ours {
            command.isEnabled = true
            tokens.append((command, command.addTarget(handler: Self.target(for: name, route: route))))
        }
    }
}

/// A Now Playing publisher for tests and for runs that must not touch the system: it records what it is
/// given, and a test can fire a command at it.
@MainActor
public final class RecordingNowPlaying: NowPlayingPublishing {
    public struct Publication: Hashable, Sendable {
        public let title: String
        public let unitIndex: Int
        public let unitCount: Int
        public let isPlaying: Bool
    }

    public var onCommand: ((NowPlayingCommand) -> MPRemoteCommandHandlerStatus)?
    public private(set) var publications: [Publication] = []
    public private(set) var withdrawCount = 0
    public private(set) var isPublished = false

    public init() {}

    public func publish(title: String, unitIndex: Int, unitCount: Int, isPlaying: Bool) {
        publications.append(Publication(title: title, unitIndex: unitIndex, unitCount: unitCount, isPlaying: isPlaying))
        isPublished = true
    }

    public func withdraw() {
        withdrawCount += 1
        isPublished = false
    }

    @discardableResult
    public func fire(_ command: NowPlayingCommand) -> MPRemoteCommandHandlerStatus {
        guard isPublished, let onCommand else { return .noActionableNowPlayingItem }
        return onCommand(command)
    }
}
