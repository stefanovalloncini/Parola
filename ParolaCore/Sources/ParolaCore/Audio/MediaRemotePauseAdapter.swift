import Foundation
import os

#if canImport(Darwin) && os(macOS)
import CoreAudio
import Darwin
#endif

struct MediaRemotePauseAdapter: MediaPlaybackToggler {
    init() {}

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
    /// macOS even while media plays (send still works), so an audibly rendering output
    /// device also counts as playing.
    func isPlaying() async -> Bool {
        #if canImport(Darwin) && os(macOS)
        if await MediaRemoteBridge.shared.isPlaying() { return true }
        return Self.defaultOutputDeviceRunningSomewhere()
        #else
        return true
        #endif
    }

    #if canImport(Darwin) && os(macOS)
    private static func defaultOutputDeviceRunningSomewhere() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
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
