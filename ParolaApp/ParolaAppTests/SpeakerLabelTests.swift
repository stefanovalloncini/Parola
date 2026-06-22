import Foundation
import Testing
import ParolaCore
@testable import Parola

@MainActor
@Suite("SegmentCard speaker label")
struct SpeakerLabelTests {
    @Test("keeps a real speaker name")
    func keepsRealSpeaker() {
        #expect(SegmentCard.speakerLabel(for: "Speaker 1") == "Speaker 1")
    }

    @Test("treats a nil speaker as no label")
    func nilIsNoLabel() {
        #expect(SegmentCard.speakerLabel(for: nil) == nil)
    }

    @Test("treats an empty-string speaker as no label")
    func emptyIsNoLabel() {
        #expect(SegmentCard.speakerLabel(for: "") == nil)
    }
}
