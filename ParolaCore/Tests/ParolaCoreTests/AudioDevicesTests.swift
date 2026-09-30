import Foundation
import Testing
@testable import ParolaCore

@Suite("AudioDevices")
struct AudioDevicesTests {
    private let namedDevices = [
        AudioInputDevice(uid: "BuiltIn", name: "MacBook Pro Microphone", isDefault: true),
        AudioInputDevice(uid: "USB-1", name: "Shure MV7", isDefault: false),
    ]

    @Test("a chosen device is named, and no choice names the default")
    func names() {
        #expect(AudioDevices.name(forUID: "USB-1", in: namedDevices) == "Shure MV7")
        #expect(AudioDevices.name(forUID: nil, in: namedDevices) == "MacBook Pro Microphone")
        #expect(AudioDevices.name(forUID: "gone", in: namedDevices) == nil)
    }

    @Test("inputDevices enumerates the host's real input devices with stable invariants")
    func inputDevicesInvariants() {
        let devices = AudioDevices.inputDevices()

        #expect(devices.filter(\.isDefault).count <= 1)

        for device in devices {
            #expect(!device.uid.isEmpty)
            #expect(!device.name.isEmpty)
        }

        for (lhs, rhs) in zip(devices, devices.dropFirst()) {
            if lhs.isDefault != rhs.isDefault {
                #expect(lhs.isDefault, "the default device must sort before any non-default one")
            } else {
                #expect(lhs.name.localizedCaseInsensitiveCompare(rhs.name) != .orderedDescending,
                        "non-default devices must be name-ascending")
            }
        }
    }

    @Test("deviceID round-trips a listed UID and rejects an unknown one")
    func deviceIDRoundTrip() {
        let devices = AudioDevices.inputDevices()

        if let first = devices.first {
            #expect(AudioDevices.deviceID(forUID: first.uid) != nil)
        }

        #expect(AudioDevices.deviceID(forUID: "parola-nonexistent-uid-\(UUID().uuidString)") == nil)
    }
}
