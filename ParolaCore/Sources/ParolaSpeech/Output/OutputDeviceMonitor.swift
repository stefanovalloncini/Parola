import AudioToolbox
import CoreAudio
import Foundation
import ParolaCore

/// Tells the reader that the output it plays to has gone: the system default output changed, or the device
/// the reading is bound to stopped. `start(boundDevice:)` replaces any earlier watch; `onChange` runs on
/// the main actor.
@MainActor
public protocol OutputDeviceMonitoring: AnyObject {
    var onChange: (@MainActor () -> Void)? { get set }

    func start(boundDevice: AudioDeviceID?)

    func stop()
}

#if os(macOS)
@MainActor
public final class OutputDeviceMonitor: OutputDeviceMonitoring {
    public var onChange: (@MainActor () -> Void)?

    private var boundDevice: AudioDeviceID?
    private var listeners: [PropertyListener] = []
    private var watch = 0

    public init() {}

    public func start(boundDevice: AudioDeviceID?) {
        stop()
        self.boundDevice = boundDevice
        let watch = self.watch
        listeners.append(PropertyListener(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ) { @Sendable [weak self] in
            Task { @MainActor in self?.defaultOutputChanged(watch: watch) }
        })
        if let boundDevice {
            listeners.append(PropertyListener(object: boundDevice, selector: kAudioDevicePropertyDeviceIsAlive) {
                @Sendable [weak self] in
                Task { @MainActor in self?.boundDeviceChanged(watch: watch) }
            })
        }
    }

    public func stop() {
        watch += 1
        listeners.removeAll()
        boundDevice = nil
    }

    private func defaultOutputChanged(watch: Int) {
        guard watch == self.watch else { return }
        if let boundDevice, OutputDevices.defaultOutput() == boundDevice { return }
        onChange?()
    }

    private func boundDeviceChanged(watch: Int) {
        guard watch == self.watch, let boundDevice, !OutputDevices.isAlive(boundDevice) else { return }
        onChange?()
    }
}

private final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private let isRegistered: Bool

    init(object: AudioObjectID, selector: AudioObjectPropertySelector, onChange: @escaping @Sendable () -> Void) {
        self.object = object
        address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        self.block = block
        isRegistered = AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr
        if !isRegistered {
            ParolaLog.error(.readAloud, "could not watch the audio output for changes")
        }
    }

    deinit {
        if isRegistered {
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
    }
}

enum OutputDevices {
    static func defaultOutput() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func isAlive(_ device: AudioDeviceID) -> Bool {
        var alive = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    static func current(of unit: AudioUnit) -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func bind(_ unit: AudioUnit, to device: AudioDeviceID) -> OSStatus {
        var device = device
        return AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }
}
#endif
