import Foundation

/// Audio source that captures live input (microphone or system audio) into a
/// temporary file. Distinct from ``AudioSource`` in that it can be started
/// independently of ``prepare()`` and keeps a ``LevelMeter`` current while recording.
///
/// Adopted by ``MicAudioSource``, ``SystemAudioSource``, and the test-mode
/// ``FixtureAudioSource``. The agent platform's mock audio command swaps real
/// sources for fixtures via ``MockAudioSourceRegistry``.
public protocol LiveAudioSource: AudioSource {
    func start() async throws
    /// Written by the capture as buffers arrive; a meter reads it when it draws.
    var levelMeter: LevelMeter { get }
    /// The file this source is capturing into, once known — lets the app checkpoint
    /// an in-flight take for crash recovery. `nil` for sources that don't record to disk.
    func inFlightURL() async -> URL?
    /// Pausing stops new audio landing in the file without ending the capture; a paused
    /// stretch is absent when it resumes.
    func setPaused(_ paused: Bool) async
}

public extension LiveAudioSource {
    func inFlightURL() async -> URL? { nil }
    var levelMeter: LevelMeter { LevelMeter() }
    func setPaused(_ paused: Bool) async {}
}

public enum LiveAudioSourceFactory {
    public static func makeMicrophone(
        deviceUID: String? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        filePrefix: String = "parola-mic"
    ) async -> any LiveAudioSource {
        if let fixtureURL = await MockAudioSourceRegistry.shared.resolve(for: .mic) {
            return FixtureAudioSource.make(fixtureURL: fixtureURL, clock: clock)
        }
        return MicAudioSource(deviceUID: deviceUID, filePrefix: filePrefix)
    }

    #if os(macOS)
    @available(macOS 13.0, *)
    public static func makeSystem(
        targetBundleIDs: Set<String> = [],
        clock: any Clock<Duration> = ContinuousClock()
    ) async -> any LiveAudioSource {
        if let fixtureURL = await MockAudioSourceRegistry.shared.resolve(for: .system) {
            return FixtureAudioSource.make(fixtureURL: fixtureURL, clock: clock)
        }
        // Targets with no audio-producing process fall back to the full mix rather
        // than recording silence.
        if #available(macOS 14.2, *), !targetBundleIDs.isEmpty {
            let objects = ProcessTapAudioSource.audioProcessObjects(matching: targetBundleIDs)
            if !objects.isEmpty {
                return ProcessTapAudioSource(processObjects: objects)
            }
        }
        return SystemAudioSource()
    }
    #endif
}
