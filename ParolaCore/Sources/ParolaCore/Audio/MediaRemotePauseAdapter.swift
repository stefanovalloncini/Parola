import Foundation

#if canImport(Darwin) && os(macOS)
import Darwin
#endif

public struct MediaRemotePauseAdapter: MediaPlaybackToggler {
    public init() {}

    public func pause() async {
        #if canImport(Darwin) && os(macOS)
        MediaRemoteBridge.shared.send(command: MediaRemoteBridge.pauseCommand)
        #endif
    }

    public func play() async {
        #if canImport(Darwin) && os(macOS)
        MediaRemoteBridge.shared.send(command: MediaRemoteBridge.playCommand)
        #endif
    }
}

#if canImport(Darwin) && os(macOS)

private final class MediaRemoteBridge: @unchecked Sendable {
    static let shared = MediaRemoteBridge()

    static let pauseCommand: Int32 = 1
    static let playCommand: Int32 = 0

    private typealias SendCommandFn = @convention(c) (Int32, CFDictionary?) -> Bool
    private let sendCommand: SendCommandFn?

    private init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            sendCommand = nil
            return
        }
        // MediaRemote is private SPI; acceptable for direct distribution, not Mac App Store.
        guard let sym = dlsym(handle, "MRMediaRemoteSendCommand") else {
            sendCommand = nil
            return
        }
        sendCommand = unsafeBitCast(sym, to: SendCommandFn.self)
    }

    func send(command: Int32) {
        _ = sendCommand?(command, nil)
    }
}

#endif
