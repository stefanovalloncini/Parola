import Foundation

/// What a reading reads aloud: the transcript (optionally from one segment on), the summary, or the
/// translation into one language.
public enum ReadingSource: Hashable, Sendable {
    case transcript(fromSegment: TranscriptSegment.ID?)
    case summary
    case translation(language: String)
}

/// The element of an entry a reading unit was taken from, so a view can find what to highlight.
/// Summary paragraphs are counted the way `ReadingScriptBuilder.summaryParagraphRanges(in:)` counts
/// them; action items are the summary's, by position.
public enum ReadingAnchor: Hashable, Sendable {
    case segment(TranscriptSegment.ID)
    case translation(segmentID: TranscriptSegment.ID)
    case summaryParagraph(Int)
    case chapter(Chapter.ID)
    case actionItem(Int)
}

/// One sentence-sized piece of a reading: what is spoken, where it came from, and the silence that
/// follows it. Ids are 0-based and dense in reading order.
public struct ReadingUnit: Identifiable, Hashable, Sendable {
    /// An element the unit was taken from and the unit's span inside that element's stored text, in
    /// UTF-16 units (`segment.text`, the translated segment text, the summary paragraph, the chapter
    /// title, the action item).
    public struct Anchored: Hashable, Sendable {
        public let anchor: ReadingAnchor
        public let range: NSRange

        public init(anchor: ReadingAnchor, range: NSRange) {
            self.anchor = anchor
            self.range = range
        }
    }

    public let id: Int
    public let text: String
    public let anchors: [Anchored]
    public let language: String?
    public let pauseAfter: Double

    public init(id: Int, text: String, anchors: [Anchored], language: String?, pauseAfter: Double) {
        self.id = id
        self.text = text
        self.anchors = anchors
        self.language = language
        self.pauseAfter = pauseAfter
    }
}
