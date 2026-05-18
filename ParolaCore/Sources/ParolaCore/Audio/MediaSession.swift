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
}

public actor MediaSession {
    private let muter: any SystemAudioMuter
    private let player: any MediaPlaybackToggler

    private var active: Bool = false
    private var wasMutedBeforeEnter: Bool?
    private var pauseIssued: Bool = false

    public init(
        muter: any SystemAudioMuter = CoreAudioMute(),
        player: any MediaPlaybackToggler = MediaRemotePauseAdapter()
    ) {
        self.muter = muter
        self.player = player
    }

    public func enterRecording(config: MediaSessionConfig) async {
        guard !active else { return }
        active = true

        if config.muteSystemAudio {
            let already = await muter.isMuted()
            wasMutedBeforeEnter = already
            if !already {
                await muter.setMuted(true)
            }
        }

        if config.pausePlayback {
            await player.pause()
            pauseIssued = true
        }
    }

    public func exitRecording() async {
        guard active else { return }
        active = false

        if let was = wasMutedBeforeEnter, was == false {
            await muter.setMuted(false)
        }
        wasMutedBeforeEnter = nil

        if pauseIssued {
            await player.play()
            pauseIssued = false
        }
    }
}
