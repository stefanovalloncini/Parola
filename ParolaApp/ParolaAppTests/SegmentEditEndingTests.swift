import Testing
@testable import Parola

@MainActor
@Suite("SegmentCard inline edit ending")
struct SegmentEditEndingTests {
    @Test("Escape writes nothing, whatever was typed")
    func cancelWritesNothing() {
        #expect(SegmentCard.EditEnding.cancel.textToWrite(draft: "Edited", original: "Original") == nil)
        #expect(SegmentCard.EditEnding.cancel.textToWrite(draft: "", original: "Original") == nil)
        #expect(SegmentCard.EditEnding.cancel.textToWrite(draft: "Original", original: "Original") == nil)
    }

    @Test("Return and focus loss write a changed draft")
    func commitWritesTheDraft() {
        #expect(SegmentCard.EditEnding.commit.textToWrite(draft: "Edited", original: "Original") == "Edited")
    }

    @Test("committing an untouched draft writes nothing, so it leaves no undo step")
    func untouchedCommitWritesNothing() {
        #expect(SegmentCard.EditEnding.commit.textToWrite(draft: "Original", original: "Original") == nil)
    }
}
