import Foundation
import Testing
@testable import ParolaCore

@Suite("AudioDevices")
struct AudioDevicesTests {
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
