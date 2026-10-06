import Testing
@testable import Parola

@Suite("Meeting prompt name")
struct ContentSheetsMeetingPromptTests {
    @Test("the live detected name wins over a stale snapshot")
    func detectedNameWins() {
        #expect(ContentSheetsModifier.meetingPromptName(detected: "Zoom", snapshot: "") == "Zoom")
    }

    @Test("the snapshot keeps the dismiss animation's name once detection clears")
    func snapshotFallsThroughOnceDetectionClears() {
        #expect(ContentSheetsModifier.meetingPromptName(detected: nil, snapshot: "Zoom") == "Zoom")
    }
}
