import Testing
@testable import Parola

@MainActor
@Suite("SegmentCard action strip")
struct SegmentCardStripTests {
    @Test("the strip shows while the pointer is on the card")
    func showsOnHover() {
        #expect(SegmentCard.showsActionStrip(hovering: true, timingPopoverOpen: false, isEditing: false))
        #expect(!SegmentCard.showsActionStrip(hovering: false, timingPopoverOpen: false, isEditing: false))
    }

    @Test("the strip stays while the timing popover it anchors is open, pointer on the card or not")
    func outlivesTheHoverForThePopover() {
        #expect(SegmentCard.showsActionStrip(hovering: false, timingPopoverOpen: true, isEditing: false))
        #expect(SegmentCard.showsActionStrip(hovering: true, timingPopoverOpen: true, isEditing: false))
    }

    @Test("an inline edit hides the strip whatever else is true")
    func editingHidesIt() {
        for hovering in [true, false] {
            for popoverOpen in [true, false] {
                #expect(!SegmentCard.showsActionStrip(hovering: hovering, timingPopoverOpen: popoverOpen, isEditing: true))
            }
        }
    }
}
