import Foundation
import Testing
@testable import Parola

@Suite("SegmentCount label")
struct SegmentCountTests {
    @Test("uses the singular noun for exactly one segment")
    func singular() {
        #expect(SegmentCount.label(1) == "1 segment")
    }

    @Test("uses the plural noun for zero and many segments")
    func plural() {
        #expect(SegmentCount.label(0) == "0 segments")
        #expect(SegmentCount.label(2) == "2 segments")
        #expect(SegmentCount.label(19) == "19 segments")
    }
}
