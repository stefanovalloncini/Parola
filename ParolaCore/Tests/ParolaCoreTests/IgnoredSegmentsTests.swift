import Foundation
import Testing
@testable import ParolaCore

@Suite("Ignored segments engine")
struct IgnoredSegmentsTests {
    private func seg(_ id: Int, _ text: String) -> TranscriptSegment {
        TranscriptSegment(id: id, start: Double(id), end: Double(id) + 1, text: text)
    }

    @Test("empty rules return segments unchanged")
    func emptyRules() {
        let input = [seg(0, "Hello"), seg(1, "uh"), seg(2, "world")]
        let out = IgnoredSegments.apply(rules: [], to: input)
        #expect(out.map(\.text) == ["Hello", "uh", "world"])
    }

    @Test("exact-match rule removes that segment")
    func exactMatch() {
        let rule = IgnoredSegmentRule(pattern: "uh")
        let input = [seg(0, "Hello"), seg(1, "uh"), seg(2, "world")]
        let out = IgnoredSegments.apply(rules: [rule], to: input)
        #expect(out.map(\.text) == ["Hello", "world"])
    }

    @Test("match is case-insensitive after trim")
    func caseInsensitive() {
        let rule = IgnoredSegmentRule(pattern: "uh")
        let input = [seg(0, "  UH  "), seg(1, "Hello")]
        let out = IgnoredSegments.apply(rules: [rule], to: input)
        #expect(out.map(\.text) == ["Hello"])
    }

    @Test("disabled rule keeps the segment")
    func disabledRule() {
        let rule = IgnoredSegmentRule(pattern: "uh", enabled: false)
        let input = [seg(0, "uh"), seg(1, "world")]
        let out = IgnoredSegments.apply(rules: [rule], to: input)
        #expect(out.map(\.text) == ["uh", "world"])
    }

    @Test("partial match keeps the segment")
    func partialMatch() {
        // Pattern is "uh" but segment is "uh okay" — keep the segment since it contains more.
        let rule = IgnoredSegmentRule(pattern: "uh")
        let input = [seg(0, "uh okay"), seg(1, "uh")]
        let out = IgnoredSegments.apply(rules: [rule], to: input)
        #expect(out.map(\.text) == ["uh okay"])
    }

    @Test("multiple rules cumulatively filter")
    func multipleRules() {
        let r1 = IgnoredSegmentRule(pattern: "uh")
        let r2 = IgnoredSegmentRule(pattern: "um")
        let input = [seg(0, "uh"), seg(1, "okay"), seg(2, "um")]
        let out = IgnoredSegments.apply(rules: [r1, r2], to: input)
        #expect(out.map(\.text) == ["okay"])
    }

    @Test("rule round-trips through JSON")
    func jsonRoundTrip() throws {
        let rule = IgnoredSegmentRule(pattern: "Hmm")
        let data = try JSONEncoder().encode([rule])
        let decoded = try JSONDecoder().decode([IgnoredSegmentRule].self, from: data)
        #expect(decoded.first?.pattern == "Hmm")
        #expect(decoded.first?.enabled == true)
    }
}
