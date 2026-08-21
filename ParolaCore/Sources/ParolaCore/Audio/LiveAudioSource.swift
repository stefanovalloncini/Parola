import Foundation

/// Audio source that captures live input (microphone or system audio) into a
/// temporary file. Distinct from ``AudioSource`` in that it can be started
/// independently of ``prepare()`` and emits a level stream while recording.
///
/// Adopted by ``MicAudioSource``, ``SystemAudioSource``, and the test-mode
/// ``FixtureAudioSource``. The agent platform's mock audio command swaps real
/// sources for fixtures via ``MockAudioSourceRegistry``.
public protocol LiveAudioSource: AudioSource {
    func start() async throws
    func levels() async -> AsyncStream<Float>
    /// The file this source is capturing into, once known — lets the app checkpoint
    /// an in-flight take for crash recovery. `nil` for sources that don't record to disk.
    func inFlightURL() async -> URL?
}

public extension LiveAudioSource {
    func inFlightURL() async -> URL? { nil }
}

public enum LiveAudioSourceFactory {
    public static func makeMicrophone(
        deviceUID: String? = nil,
        clock: any Clock<Duration> = ContinuousClock()
    ) async -> any LiveAudioSource {
        if let fixtureURL = await MockAudioSourceRegistry.shared.resolve(for: .mic) {
            return FixtureAudioSource.make(fixtureURL: fixtureURL, clock: clock)
        }
        return MicAudioSource(deviceUID: deviceUID)
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
