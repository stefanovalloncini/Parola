import CoreAudio
import Foundation
import ParolaSpeech

@MainActor
final class FakeOutputDeviceMonitor: OutputDeviceMonitoring {
    var onChange: (@MainActor () -> Void)?
    private(set) var starts: [AudioDeviceID?] = []
    private(set) var stops = 0
    private(set) var isWatching = false

    func start(boundDevice: AudioDeviceID?) {
        starts.append(boundDevice)
        isWatching = true
    }

    func stop() {
        stops += 1
        isWatching = false
    }

    func simulateChange() {
        onChange?()
    }
}
