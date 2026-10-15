import Foundation

#if canImport(CoreAudio)
import CoreAudio
#endif

public struct MediaSessionConfig: Sendable, Equatable {
    public let muteSystemAudio: Bool
    public let pausePlayback: Bool

    public init(muteSystemAudio: Bool, pausePlayback: Bool) {
        self.muteSystemAudio = muteSystemAudio
        self.pausePlayback = pausePlayback
    }

    public static let none = MediaSessionConfig(muteSystemAudio: false, pausePlayback: false)
}

public protocol SystemAudioMuter: Sendable {
    func isMuted() async -> Bool
    func setMuted(_ muted: Bool) async
}

public protocol MediaPlaybackToggler: Sendable {
    func pause() async
    func play() async
    func isPlaying() async -> Bool
}

public extension MediaPlaybackToggler {
    func isPlaying() async -> Bool { true }
}

/// The app's own players, which the system-wide pause doesn't reach.
public protocol OwnPlaybackControl: Sendable {
    func pausePlaying() async -> Bool
    func resumePaused() async
}

public actor MediaSession {
    private let muter: any SystemAudioMuter
    private let player: any MediaPlaybackToggler
    private let ownPlayback: (any OwnPlaybackControl)?
    private var ownPlaybackPaused = false

    private var holders = 0
    private var generation = 0
    private var wasMutedBeforeEnter: Bool?
    private var pauseIssued: Bool = false

    public init(
        muter: (any SystemAudioMuter)? = nil,
        player: (any MediaPlaybackToggler)? = nil,
        ownPlayback: (any OwnPlaybackControl)? = nil
    ) {
        self.muter = muter ?? CoreAudioMute()
        self.player = player ?? MediaRemotePauseAdapter()
        self.ownPlayback = ownPlayback
    }

    /// The first holder applies the mute and pauses; later holders (a dictation during a take) only count.
    public func enterRecording(config: MediaSessionConfig) async {
        holders += 1
        guard holders == 1 else { return }
        let ticket = generation

        if config.muteSystemAudio {
            let already = await muter.isMuted()
            guard generation == ticket else { return }
            wasMutedBeforeEnter = already
            if !already {
                await muter.setMuted(true)
                guard generation == ticket else {
                    await muter.setMuted(false)
                    return
                }
            }
        }

        if config.pausePlayback, let ownPlayback {
            let paused = await ownPlayback.pausePlaying()
            guard generation == ticket else {
                if paused { await ownPlayback.resumePaused() }
                return
            }
            ownPlaybackPaused = paused
        }

        // Only pause (and later resume) when something was actually playing, mirroring
        // the mute path's snapshot — a blind play on exit would start paused media.
        if config.pausePlayback {
            let playing = await player.isPlaying()
            guard generation == ticket, playing else { return }
            await player.pause()
            guard generation == ticket else {
                await player.play()
                return
            }
            pauseIssued = true
        }
    }

    public func exitRecording() async {
        guard holders > 0 else { return }
        holders -= 1
        guard holders == 0 else { return }
        generation += 1

        if let was = wasMutedBeforeEnter, was == false {
            await muter.setMuted(false)
        }
        wasMutedBeforeEnter = nil

        if ownPlaybackPaused, let ownPlayback {
            ownPlaybackPaused = false
            await ownPlayback.resumePaused()
        }

        if pauseIssued {
            await player.play()
            pauseIssued = false
        }
    }
}
