import Testing
@testable import Parola
import ParolaCore

@Suite("Live captions pane")
struct LiveCaptionsPaneTests {
    @Test("the pane asks for the one permission its source needs")
    func neededPermission() {
        #expect(LiveCaptionsPane.neededPermission(for: .microphone(deviceUID: nil)) == nil)
        #expect(LiveCaptionsPane.neededPermission(for: .systemAudio) == .screenRecording)
        #expect(LiveCaptionsPane.neededPermission(for: .app(bundleID: "us.zoom.xos")) == .systemAudioRecording)
    }
}
