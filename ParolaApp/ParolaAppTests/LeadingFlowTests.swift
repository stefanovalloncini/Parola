import AppKit
import SwiftUI
import Testing
@testable import Parola

@Suite("Leading flow row gap")
@MainActor
struct LeadingFlowTests {

    /// Two 120-wide items in a 150-wide flow, so they always land on separate rows.
    private func height(spacing: CGFloat, rowSpacing: CGFloat?) -> CGFloat {
        let flow = LeadingFlow(spacing: spacing, rowSpacing: rowSpacing) {
            ForEach(0..<2, id: \.self) { _ in
                Color.clear.frame(width: 120, height: 20)
            }
        }
        return NSHostingView(rootView: flow.frame(width: 150)).fittingSize.height
    }

    @Test("the gap between rows is the row spacing, not the item spacing")
    func rowGapComesFromRowSpacing() {
        #expect(height(spacing: 4, rowSpacing: 5) == 45)
        #expect(height(spacing: 4, rowSpacing: 12) == 52)
    }

    @Test("a flow with no row spacing puts its item spacing between the rows")
    func rowGapFallsBackToSpacing() {
        #expect(height(spacing: 4, rowSpacing: nil) == 44)
        #expect(height(spacing: 9, rowSpacing: nil) == 49)
    }

    @Test("the demo card's word flow keeps the transcript leading between its rows")
    func demoCardUsesTheTranscriptLeading() {
        let withToken = height(spacing: DS.Spacing.tight, rowSpacing: DS.Spacing.transcriptLeading)
        #expect(withToken == 40 + DS.Spacing.transcriptLeading)
        #expect(withToken != height(spacing: DS.Spacing.tight, rowSpacing: nil))
    }
}
