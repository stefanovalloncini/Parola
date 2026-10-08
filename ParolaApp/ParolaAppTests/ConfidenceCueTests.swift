import Foundation
import Testing
import ParolaCore
@testable import Parola

@Suite("Confidence reads without colour")
struct ConfidenceCueTests {
    private func source(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/ConfidenceCueTests.swift",
            with: "ParolaApp/\(name).swift"
        )
        return try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("a low segment names its confidence; medium and high leave the card alone")
    func lowConfidenceHasANote() {
        #expect(SegmentCard.confidenceNote(.low) == "Low confidence")
        #expect(SegmentCard.confidenceNote(.medium) == nil)
        #expect(SegmentCard.confidenceNote(.high) == nil)
        #expect(SegmentCard.confidenceNote(nil) == nil)
    }

    @Test("the note is a labelled glyph beside the time")
    func cuesReachVoiceOver() throws {
        let card = try source("Views/Transcript/SegmentCard")
        #expect(card.contains(#"if let note = Self.confidenceNote(confidenceBucket) { Image(systemName: "exclamationmark")"#))
        #expect(card.contains(".help(note) .accessibilityLabel(note)"))
    }
}
