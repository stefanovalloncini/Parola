import Testing
import Foundation
@testable import ParolaCore

@Suite("Caption source")
struct CaptionSourceTests {
    @Test("each source survives its stored string")
    func roundTrip() {
        let sources: [CaptionSource] = [.microphone(deviceUID: nil), .systemAudio, .app(bundleID: "us.zoom.xos")]
        for source in sources {
            #expect(CaptionSource(setting: source.setting) == source)
        }
        #expect(CaptionSource.app(bundleID: "com.apple.Safari").setting == "app:com.apple.Safari")
    }

    @Test("a microphone source takes the input device it is given and stores none")
    func microphoneCarriesTheDevice() {
        let source = CaptionSource(setting: "microphone", deviceUID: "usb-mic")
        #expect(source == .microphone(deviceUID: "usb-mic"))
        #expect(source.setting == "microphone")
        #expect(source.deviceUID == "usb-mic")
        #expect(CaptionSource.systemAudio.deviceUID == nil)
    }

    @Test("unknown, empty and half-written values read as the microphone")
    func garbageIsTheMicrophone() {
        for value in [nil, "", "speakers", "app:", "App:zoom", "systemaudio", "  "] as [String?] {
            #expect(CaptionSource(setting: value, deviceUID: "x") == .microphone(deviceUID: "x"), "\(value ?? "nil")")
        }
    }

    @Test("the codable form round-trips")
    func codable() throws {
        let source = CaptionSource.app(bundleID: "us.zoom.xos")
        let data = try JSONEncoder().encode(source)
        #expect(try JSONDecoder().decode(CaptionSource.self, from: data) == source)
    }
}
