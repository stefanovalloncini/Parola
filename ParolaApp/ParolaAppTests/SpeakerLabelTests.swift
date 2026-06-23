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

    @Test("treats a whitespace-only speaker as no label")
    func whitespaceOnlyIsNoLabel() {
        #expect(SegmentCard.speakerLabel(for: "   ") == nil)
        #expect(SegmentCard.speakerLabel(for: "\n") == nil)
    }

    @Test("trims surrounding whitespace from a padded speaker")
    func trimsPaddedSpeaker() {
        #expect(SegmentCard.speakerLabel(for: " Anna ") == "Anna")
    }

    @Test("flattens internal newlines to a single line")
    func flattensNewlines() {
        #expect(SegmentCard.speakerLabel(for: "Marco\nRossi") == "Marco Rossi")
        #expect(SegmentCard.speakerLabel(for: "A\nB\nC") == "A B C")
    }
}
