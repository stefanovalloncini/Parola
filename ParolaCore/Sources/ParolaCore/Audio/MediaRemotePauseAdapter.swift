import Foundation
import os

#if canImport(Darwin) && os(macOS)
import CoreAudio
import Darwin
#endif

/// One process the audio hardware knows about, as reported by `kAudioHardwarePropertyProcessObjectList`.
struct OutputProcess: Sendable, Equatable {
    let pid: pid_t
    let isRunningOutput: Bool
}

/// Supplies the processes currently known to the audio hardware. Tests inject a fixture;
/// the default reads `kAudioHardwarePropertyProcessObjectList` and never runs off the main test suite.
typealias OutputActivityProbe = @Sendable () -> [OutputProcess]

struct MediaRemotePauseAdapter: MediaPlaybackToggler {
    private let outputActivityProbe: OutputActivityProbe

    init(outputActivityProbe: @escaping OutputActivityProbe = Self.liveOutputActivityProbe) {
        self.outputActivityProbe = outputActivityProbe
    }

    func pause() async {
        #if canImport(Darwin) && os(macOS)
        MediaRemoteBridge.shared.send(command: MediaRemoteBridge.pauseCommand)
        #endif
    }

    func play() async {
        #if canImport(Darwin) && os(macOS)
        MediaRemoteBridge.shared.send(command: MediaRemoteBridge.playCommand)
        #endif
    }

    /// MediaRemote's now-playing query answers false to unentitled GUI apps on modern
    /// macOS even while media plays (send still works), so a process other than Parola's
    /// own that is actively rendering output also counts as playing.
    func isPlaying() async -> Bool {
        #if canImport(Darwin) && os(macOS)
        let mediaRemoteSaysPlaying = await MediaRemoteBridge.shared.isPlaying()
        return Self.decide(mediaRemoteSaysPlaying: mediaRemoteSaysPlaying, processes: outputActivityProbe())
        #else
        return true
        #endif
    }

    static func decide(mediaRemoteSaysPlaying: Bool, processes: [OutputProcess]) -> Bool {
        if mediaRemoteSaysPlaying { return true }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return processes.contains { $0.pid != ownPID && $0.isRunningOutput }
    }

    #if canImport(Darwin) && os(macOS)
    static func liveOutputActivityProbe() -> [OutputProcess] {
        AudioProcessObjectList.current().compactMap { object in
            guard let pid = pid(of: object), let isRunningOutput = isRunningOutput(of: object) else { return nil }
            return OutputProcess(pid: pid, isRunningOutput: isRunningOutput)
        }
    }

    private static func pid(of processObject: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(processObject, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func isRunningOutput(of processObject: AudioObjectID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(processObject, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }
    #else
    static func liveOutputActivityProbe() -> [OutputProcess] { [] }
    #endif
}

#if canImport(Darwin) && os(macOS)

/// Unchecked Sendable: `dlopen` handle and function pointers are loaded once at init and read-only after.
private final class MediaRemoteBridge: @unchecked Sendable {
    static let shared = MediaRemoteBridge()

    static let pauseCommand: Int32 = 1
    static let playCommand: Int32 = 0

    private typealias SendCommandFn = @convention(c) (Int32, CFDictionary?) -> Bool
    private typealias GetIsPlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    private let sendCommand: SendCommandFn?
    private let getIsPlaying: GetIsPlayingFn?

    private init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            sendCommand = nil
            getIsPlaying = nil
            return
        }
        // MediaRemote is private SPI; acceptable for direct distribution, not Mac App Store.
        sendCommand = dlsym(handle, "MRMediaRemoteSendCommand").map {
            unsafeBitCast($0, to: SendCommandFn.self)
        }
        getIsPlaying = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying").map {
            unsafeBitCast($0, to: GetIsPlayingFn.self)
        }
    }

    func send(command: Int32) {
        _ = sendCommand?(command, nil)
    }

    /// Defaults to true (the pre-query behavior) when the symbol is missing or the
    /// callback never arrives, so recording start can't hang on the SPI.
    func isPlaying() async -> Bool {
        guard let getIsPlaying else { return true }
        return await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Bool) -> Void = { value in
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume(returning: value) }
            }
            getIsPlaying(DispatchQueue.global()) { playing in finish(playing) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { finish(true) }
        }
    }
}

#endif
