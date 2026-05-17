#if os(macOS)
import Foundation
import Testing
@testable import ParolaCore

@Suite("YouTube subs dedup")
struct YouTubeSubsDedupTests {
    @Test("strippingOverlap removes the suffix-prefix overlap between consecutive segments")
    func overlapDetection() {
        let stripped = YouTubeSubsFetcher.strippingOverlap(
            of: "hello world how",
            from: "world how are you"
        )
        #expect(stripped == "are you")
    }

    @Test("strippingOverlap returns nil when there is no shared word boundary")
    func noOverlap() {
        #expect(YouTubeSubsFetcher.strippingOverlap(of: "alpha bravo", from: "charlie delta") == nil)
    }

    @Test("strippingOverlap matches whole words only — no partial-word overlap")
    func wordAligned() {
        // 'world' is in both but only as a full word, so the overlap is exactly "world".
        let stripped = YouTubeSubsFetcher.strippingOverlap(of: "say world", from: "world peace")
        #expect(stripped == "peace")
    }

    @Test("dedupeRollingCaptions collapses YouTube's rolling auto-caption pattern")
    func rollingCaptions() {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0.0, end: 2.5, text: "Permettetemi di iniziare questa"),
                TranscriptSegment(id: 1, start: 2.5, end: 2.51, text: "Permettetemi di iniziare questa"),
                TranscriptSegment(id: 2, start: 2.51, end: 5.7, text: "Permettetemi di iniziare questa chiacchierata molto frivola"),
                TranscriptSegment(id: 3, start: 5.7, end: 5.71, text: "chiacchierata molto frivola"),
                TranscriptSegment(id: 4, start: 5.71, end: 9.1, text: "chiacchierata molto frivola con un enorme abbraccio"),
            ],
            language: "it",
            modelName: "youtube-auto-subs"
        )
        let cleaned = YouTubeSubsFetcher.dedupeRollingCaptions(transcript)
        let texts = cleaned.segments.map(\.text)
        #expect(texts == [
            "Permettetemi di iniziare questa",
            "chiacchierata molto frivola",
            "con un enorme abbraccio",
        ])
    }

    @Test("dedupeRollingCaptions leaves professional (non-overlapping) cues alone")
    func professionalCues() {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0.0, end: 1.5, text: "Hello world."),
                TranscriptSegment(id: 1, start: 1.5, end: 3.0, text: "Goodbye world."),
            ],
            language: "en",
            modelName: "youtube-subs"
        )
        let cleaned = YouTubeSubsFetcher.dedupeRollingCaptions(transcript)
        #expect(cleaned.segments.map(\.text) == ["Hello world.", "Goodbye world."])
    }

    @Test("dedupeRollingCaptions drops sub-100ms finalisation cues")
    func dropsShortFinalisations() {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0.0, end: 2.0, text: "one"),
                TranscriptSegment(id: 1, start: 2.0, end: 2.01, text: "one"),
                TranscriptSegment(id: 2, start: 2.01, end: 4.0, text: "one two"),
            ],
            language: "en",
            modelName: "youtube-auto-subs"
        )
        let cleaned = YouTubeSubsFetcher.dedupeRollingCaptions(transcript)
        #expect(cleaned.segments.map(\.text) == ["one", "two"])
    }
}
#endif
