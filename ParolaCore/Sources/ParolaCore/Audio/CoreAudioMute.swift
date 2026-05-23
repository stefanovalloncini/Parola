import Foundation

#if canImport(CoreAudio) && os(macOS)
import CoreAudio
#endif

struct CoreAudioMute: SystemAudioMuter {
    init() {}

    func isMuted() async -> Bool {
        #if canImport(CoreAudio) && os(macOS)
        guard let device = Self.defaultOutputDeviceID() else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let result = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return result == noErr && value != 0
        #else
        return false
        #endif
    }

    func setMuted(_ muted: Bool) async {
        #if canImport(CoreAudio) && os(macOS)
        guard let device = Self.defaultOutputDeviceID() else { return }
        var value: UInt32 = muted ? 1 : 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectSetPropertyData(
            device, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &value
        )
        #endif
    }

    #if canImport(CoreAudio) && os(macOS)
    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return result == noErr ? deviceID : nil
    }
    #endif
}
