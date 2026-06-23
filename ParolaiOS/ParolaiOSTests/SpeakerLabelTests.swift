import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Segment speaker label")
struct SpeakerLabelTests {
    @Test("keeps a real speaker name")
    func keepsRealSpeaker() {
        #expect(TranscriptDetailView.speakerLabel(for: "Speaker 1") == "Speaker 1")
    }

    @Test("treats a nil speaker as no label")
    func nilIsNoLabel() {
        #expect(TranscriptDetailView.speakerLabel(for: nil) == nil)
    }

    @Test("treats an empty-string speaker as no label")
    func emptyIsNoLabel() {
        #expect(TranscriptDetailView.speakerLabel(for: "") == nil)
    }

    @Test("treats a whitespace-only speaker as no label")
    func whitespaceOnlyIsNoLabel() {
        #expect(TranscriptDetailView.speakerLabel(for: "   ") == nil)
        #expect(TranscriptDetailView.speakerLabel(for: "\n") == nil)
    }

    @Test("trims surrounding whitespace from a padded speaker")
    func trimsPaddedSpeaker() {
        #expect(TranscriptDetailView.speakerLabel(for: " Anna ") == "Anna")
    }

    @Test("flattens internal newlines to a single line")
    func flattensNewlines() {
        #expect(TranscriptDetailView.speakerLabel(for: "Marco\nRossi") == "Marco Rossi")
        #expect(TranscriptDetailView.speakerLabel(for: "A\nB\nC") == "A B C")
    }
}
