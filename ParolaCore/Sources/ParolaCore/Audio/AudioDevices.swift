import Foundation

#if canImport(CoreAudio)
import CoreAudio
#endif

public struct AudioInputDevice: Sendable, Identifiable, Hashable {
    public let uid: String
    public let name: String
    public let isDefault: Bool

    public var id: String { uid }

    public init(uid: String, name: String, isDefault: Bool) {
        self.uid = uid
        self.name = name
        self.isDefault = isDefault
    }
}

public enum AudioDevices {
    public static func inputDevices() -> [AudioInputDevice] {
        #if canImport(CoreAudio) && os(macOS)
        let allIDs = systemDeviceIDs()
        let defaultID = defaultInputDeviceID()
        var out: [AudioInputDevice] = []
        for id in allIDs {
            guard hasInputStreams(id) else { continue }
            guard let uid = deviceUID(id), let name = deviceName(id) else { continue }
            out.append(AudioInputDevice(uid: uid, name: name, isDefault: id == defaultID))
        }
        out.sort { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return out
        #else
        return []
        #endif
    }

    /// The name of the device with `uid`, or the default device's name when `uid` is nil.
    public static func name(forUID uid: String?, in devices: [AudioInputDevice]) -> String? {
        guard let uid else { return devices.first { $0.isDefault }?.name }
        return devices.first { $0.uid == uid }?.name
    }

    #if canImport(CoreAudio) && os(macOS)
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        for id in systemDeviceIDs() {
            if deviceUID(id) == uid { return id }
        }
        return nil
    }

    public static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return result == noErr ? deviceID : nil
    }

    private static func systemDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return false }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return false
        }
        let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
        for buffer in ablPointer where buffer.mNumberChannels > 0 { return true }
        return false
    }

    private static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        getStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        getStringProperty(deviceID: deviceID, selector: kAudioObjectPropertyName)
    }

    private static func getStringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let result = withUnsafeMutablePointer(to: &cfStr) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard result == noErr, let cf = cfStr?.takeRetainedValue() else { return nil }
        return cf as String
    }
    #endif
}
