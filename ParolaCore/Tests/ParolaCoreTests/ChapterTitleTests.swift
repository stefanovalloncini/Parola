import Foundation
import Testing
@testable import ParolaCore

@Suite("Chapter title cleaning")
struct ChapterTitleTests {
    @Test("strips a trailing hyphen delimiter")
    func stripsTrailingHyphen() {
        #expect(ChapterTitle.clean("Introduction -") == "Introduction")
    }

    @Test("strips a trailing em dash")
    func stripsTrailingEmDash() {
        #expect(ChapterTitle.clean("Wrap up —") == "Wrap up")
    }

    @Test("strips a trailing bullet")
    func stripsTrailingBullet() {
        #expect(ChapterTitle.clean("Main topic •") == "Main topic")
    }

    @Test("strips matching dash delimiters on both ends")
    func stripsBothDashEnds() {
        #expect(ChapterTitle.clean("— Introduction —") == "Introduction")
    }

    @Test("keeps a hyphen inside a word")
    func keepsInternalHyphen() {
        #expect(ChapterTitle.clean("Follow-up plan") == "Follow-up plan")
    }

    @Test("keeps an internal range dash while dropping a trailing one")
    func keepsInternalRangeDash() {
        #expect(ChapterTitle.clean("1990–2000 –") == "1990–2000")
    }

    @Test("strips leading list markers")
    func stripsLeadingMarkers() {
        #expect(ChapterTitle.clean("- Recap") == "Recap")
    }

    @Test("strips surrounding quotes and bold markup")
    func stripsQuotesAndBold() {
        #expect(ChapterTitle.clean("**\"Opening Remarks\"**") == "Opening Remarks")
    }

    @Test("an all-decorator title cleans to empty")
    func allDecoratorIsEmpty() {
        #expect(ChapterTitle.clean("— •").isEmpty)
    }
}
